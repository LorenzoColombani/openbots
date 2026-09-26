import Foundation
import os
import OpenBotsDomain

public enum AgenticJobPhase: Equatable, Sendable {
    case preparing, working, changingDirection, waitingForApproval, stopping, completed, stopped
    case failed(String)

    public var acceptsCorrections: Bool {
        switch self {
        case .working, .changingDirection, .waitingForApproval: true
        default: false
        }
    }
    public var isActive: Bool {
        switch self {
        case .completed, .stopped, .failed: false
        default: true
        }
    }
}

/// Presentation of one live, job-bound decision. It cannot execute an action.
public struct AgenticJobApproval: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let runID: RunID
    public let conversationGeneration: UInt64
    public let title: String
    public let detail: String
    public let target: String
    public let expiresAt: Date

    public init(id: UUID, runID: RunID, conversationGeneration: UInt64, title: String,
                detail: String, target: String, expiresAt: Date) {
        self.id = id; self.runID = runID; self.conversationGeneration = conversationGeneration
        self.title = title; self.detail = detail; self.target = target; self.expiresAt = expiresAt
    }
}

public struct AgenticJobProgress: Equatable, Sendable {
    public static let maximumObservations = 12
    public static let maximumObservationBytes = 512
    public let runID: RunID
    public let conversationID: ConversationID
    public let phase: AgenticJobPhase
    public let text: String
    public let approval: AgenticJobApproval?
    public let conversationGeneration: UInt64
    /// Plain lines naming what the job did without a card (each web search or
    /// page), oldest first, bounded. Display only; never an input to policy.
    public let observations: [String]
    public init(runID: RunID, conversationID: ConversationID, phase: AgenticJobPhase,
                text: String = "", approval: AgenticJobApproval? = nil, conversationGeneration: UInt64 = 0,
                observations: [String] = []) {
        self.runID = runID; self.conversationID = conversationID; self.phase = phase
        self.text = text; self.approval = approval; self.conversationGeneration = conversationGeneration
        self.observations = observations
    }
}

/// The caller saves this message through the existing chat service first.
public struct AgenticJobInput: Sendable {
    public let teammateID: TeammateID
    public let message: Message
    public let text: String
    public init(teammateID: TeammateID, message: Message, text: String) {
        self.teammateID = teammateID; self.message = message; self.text = text
    }
}

public enum AgenticJobDriverEvent: Sendable {
    case conversation(generation: UInt64, sessionID: UUID)
    case worker(AgenticJobWorker)
    case checkpoint(AgenticJobCheckpoint)
    case inputSubmitted(MessageID, sequence: Int64)
    case inputAcknowledged(MessageID, sequence: Int64)
    case text(String)
    case approval(AgenticJobApproval)
    case approvalResolved(UUID)
    case approvalCancelled(UUID)
    /// One visible line about a tool use that needed no card (a web search or page).
    case observation(String)
}

public enum AgenticJobDriverOutcome: Sendable {
    case completed(String), stopped, failed(String)
}

/// Native implementations own admitted processes and all cleanup. A returned
/// outcome must not precede owned-process teardown. No default executor exists.
public protocol AgenticJobDriving: Sendable {
    func run(_ request: WorkRequest,
             event: @escaping @Sendable (AgenticJobDriverEvent) async throws -> Void) async -> AgenticJobDriverOutcome
    func steer(_ input: SteeringInput, runID: RunID) async throws
    func decide(approvalID: UUID, allow: Bool, runID: RunID, conversationGeneration: UInt64) async throws
    func stop(runID: RunID) async
}

public protocol AgenticJobServing: Sendable {
    func submit(_ input: AgenticJobInput,
                progress: @escaping @Sendable (AgenticJobProgress) async -> Void) async throws -> RunID
    func decide(_ approval: AgenticJobApproval, allow: Bool) async throws
    func stop(conversationID: ConversationID) async
    func history(conversationID: ConversationID) async throws -> [AgenticJobRecord]
    func shutdown() async
}

/// One logical run owns all conversational replacements and worker records.
/// Ordinary chat/memory keeps its existing service and single-turn protections.
public actor AgenticJobService: AgenticJobServing {
    private struct Job {
        var record: AgenticJobRecord
        let token: UUID
        var nextInput: Int64 = 2
        var progress: @Sendable (AgenticJobProgress) async -> Void
        var phase: AgenticJobPhase = .preparing
        var text = ""
        var observations: [String] = []
        var approval: AgenticJobApproval?
        var decisionInFlight: UUID?
        var task: Task<Void, Never>?
        var operation: Task<Void, Error>?
    }
    private enum Submission {
        case start(WorkRequest)
        case steer(RunID, Task<Void, Error>)
        var runID: RunID {
            switch self { case .start(let request): request.runID; case .steer(let id, _): id }
        }
    }
    private let repository: any AgenticJobRepository
    private let teammates: any TeammateRepository
    private let conversations: any ConversationRepository
    private let messages: any MessageRepository
    private let contexts: (any ConversationContextRepository)?
    private let driver: any AgenticJobDriving
    private let clock: any OpenBotsClock
    private let ownerID = UUID()
    private var jobs: [ConversationID: Job] = [:]
    /// Every drive started for a conversation's current run. A drive clears its
    /// job's `task` just before it returns, so `jobs` alone cannot show shutdown
    /// a drive that is still finishing; this can (a macos-15 run released the
    /// store late without it).
    private var drives: [ConversationID: Task<Void, Never>] = [:]
    private var epochs: [ConversationID: UInt64] = [:]
    private var stoppedRuns = Set<RunID>()
    private var failures: [RunID: String] = [:]
    private var databaseOwners = Set<ConversationID>()
    private var databaseWaiters: [ConversationID: [CheckedContinuation<Void, Never>]] = [:]
    private var closing = false

    public init(repository: any AgenticJobRepository, teammates: any TeammateRepository,
                conversations: any ConversationRepository, messages: any MessageRepository,
                driver: any AgenticJobDriving, contexts: (any ConversationContextRepository)? = nil,
                clock: any OpenBotsClock = SystemClock()) {
        self.repository = repository; self.teammates = teammates; self.conversations = conversations
        self.messages = messages; self.driver = driver; self.clock = clock
        self.contexts = contexts ?? (repository as? any ConversationContextRepository)
    }

    public func submit(_ input: AgenticJobInput,
                       progress: @escaping @Sendable (AgenticJobProgress) async -> Void) async throws -> RunID {
        let id = input.message.conversationID, epoch = epochs[input.message.conversationID, default: 0]
        guard !closing else { throw AgenticJobError.unavailable }
        let submission: Submission
        do { submission = try await prepare(input, epoch: epoch, progress: progress) }
        catch { await publish(id); throw error }
        await publish(id)
        switch submission {
        case .start(let request):
            guard permitted(id, runID: request.runID, epoch: epoch) else {
                await stop(conversationID: id)
                throw CancellationError()
            }
            let task = Task { [weak self] in
                guard let self else { return }
                await self.drive(request, conversationID: id, epoch: epoch)
            }
            jobs[id]?.task = task
            drives[id] = task
        case .steer(let runID, let task):
            do { try await task.value }
            catch {
                await failAndStop(runID: runID, conversationID: id, explanation: "The correction was saved, but its delivery could not be confirmed.")
                throw error
            }
        }
        return submission.runID
    }

    private func prepare(_ input: AgenticJobInput, epoch: UInt64,
                         progress: @escaping @Sendable (AgenticJobProgress) async -> Void) async throws -> Submission {
        let id = input.message.conversationID
        await acquire(id)
        defer { release(id) }
        try checkPreparation(id, epoch: epoch)
        guard input.message.author == .user, input.message.outputClass == .conversation,
              !input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              input.text.utf8.count <= 8_192, !input.text.utf8.contains(0),
              let saved = try await messages.message(id: input.message.id), matchesSavedMessage(saved, input.message),
              try exactText(saved).utf8.elementsEqual(input.text.utf8),
              try exactText(input.message).utf8.elementsEqual(input.text.utf8),
              let teammate = try await teammates.teammate(id: input.teammateID), teammate.id == input.teammateID,
              teammate.lifecycle == .active, !teammate.isHidden,
              let conversation = try await conversations.conversation(id: id), conversation.id == id,
              conversation.lifecycle == .active, conversation.kind == .direct(teammateID: input.teammateID) else {
            throw AgenticJobError.invalidState
        }
        try checkPreparation(id, epoch: epoch)
        if var job = jobs[id], job.task != nil || !terminal(job.record.journal.state) {
            guard job.phase.acceptsCorrections, !stoppedRuns.contains(job.record.id), job.nextInput <= 8 else {
                throw AgenticJobError.invalidTransition
            }
            job.record = try await currentRecord(job.record.id)
            let steering = try SteeringInput(messageID: saved.id, sequence: job.nextInput, text: input.text, submittedAt: clock.now())
            let journal = try await repository.queueRunInput(id: job.record.id, expectedRevision: job.record.journal.revision,
                token: job.token, input: steering, now: clock.now())
            job.record = replacingJournal(job.record, with: journal)
            job.nextInput += 1; job.phase = .changingDirection; job.approval = nil; job.decisionInFlight = nil
            job.progress = progress
            let previous = job.operation, runID = job.record.id, driver = self.driver
            let operation = Task { [weak self] in
                try await previous?.value
                guard let self, await self.permitted(id, runID: runID, epoch: epoch), !Task.isCancelled else { throw CancellationError() }
                try await driver.steer(steering, runID: runID)
            }
            job.operation = operation; jobs[id] = job
            return .steer(runID, operation)
        }
        let context = try await contexts?.loadContext(conversationID: id)
        guard context == nil || context?.teammateID == teammate.id else { throw AgenticJobError.invalidState }
        try checkPreparation(id, epoch: epoch)
        try await recoverAbandonedRuns(conversationID: id)
        try checkPreparation(id, epoch: epoch)
        let request = try WorkRequest(runID: RunID(UUID()), teammateID: teammate.id, conversationID: id,
            initiatingMessageID: saved.id, selectedProjectID: context?.projectID, profileRevision: teammate.profile.revision,
            initialInput: WorkInput(messageID: saved.id, sequence: 1, text: input.text), submittedAt: clock.now())
        let created = try await repository.createAgenticJob(request: request)
        let token = UUID()
        jobs[id] = Job(record: created, token: token, progress: progress)
        do {
            // Claim even if Stop arrived during creation, solely to close this
            // newly created run durably. No driver is called under this gate.
            let claimed = try await repository.claimRun(id: request.runID, expectedRevision: created.journal.revision,
                ownerID: ownerID, token: token, now: clock.now(), leaseDuration: 300)
            jobs[id]?.record = replacingJournal(created, with: claimed)
            try checkPreparation(id, epoch: epoch)
        } catch {
            if closing || epochs[id, default: 0] != epoch || Task.isCancelled { stoppedRuns.insert(request.runID) }
            else { failures[request.runID] = "The job was saved, but preparation could not be completed." }
            // Unstructured cleanup does not inherit a cancelled submit task;
            // repository cancellation checks must still allow terminal recording.
            await Task { await self.finishLocked(.stopped, conversationID: id, runID: request.runID) }.value
            throw error
        }
        return .start(request)
    }

    private func drive(_ request: WorkRequest, conversationID: ConversationID, epoch: UInt64) async {
        guard permitted(conversationID, runID: request.runID, epoch: epoch), !Task.isCancelled else {
            await finish(.stopped, conversationID: conversationID, runID: request.runID)
            if jobs[conversationID]?.record.id == request.runID { jobs[conversationID]?.task = nil }
            return
        }
        let outcome = await driver.run(request) { [weak self] event in
            guard let self else { throw AgenticJobError.unavailable }
            try await self.receive(event, conversationID: conversationID, runID: request.runID)
        }
        await finish(outcome, conversationID: conversationID, runID: request.runID)
        if jobs[conversationID]?.record.id == request.runID { jobs[conversationID]?.task = nil }
    }

    public func decide(_ approval: AgenticJobApproval, allow: Bool) async throws {
        guard let id = jobs.first(where: { $0.value.record.id == approval.runID })?.key else { throw AgenticJobError.staleGeneration }
        await acquire(id)
        let operation: Task<Void, Error>
        do {
            guard !closing, var job = jobs[id], !stoppedRuns.contains(approval.runID), job.approval == approval,
                  approval.expiresAt > clock.now(), job.record.state.conversationGeneration == approval.conversationGeneration else {
                throw AgenticJobError.staleGeneration
            }
            job.approval = nil; job.decisionInFlight = approval.id
            let previous = job.operation, driver = self.driver
            operation = Task { [weak self] in
                try await previous?.value
                guard let self, await self.decisionPermitted(approval), !Task.isCancelled else { throw AgenticJobError.staleGeneration }
                try await driver.decide(approvalID: approval.id, allow: allow, runID: approval.runID,
                    conversationGeneration: approval.conversationGeneration)
            }
            job.operation = operation; jobs[id] = job
            release(id)
        } catch { release(id); throw error }
        await publish(id)
        do { try await operation.value }
        catch {
            await failAndStop(runID: approval.runID, conversationID: id, explanation: "The approval decision could not be confirmed; the job was stopped.")
            throw error
        }
    }

    public func stop(conversationID id: ConversationID) async {
        epochs[id, default: 0] &+= 1
        if let job = jobs[id] { stoppedRuns.insert(job.record.id) }
        await acquire(id)
        var runID: RunID?
        if var job = jobs[id], !terminal(job.record.journal.state) {
            runID = job.record.id; stoppedRuns.insert(job.record.id)
            job.approval = nil; job.decisionInFlight = nil; job.phase = .stopping; jobs[id] = job
            if job.task == nil { await finishLocked(.stopped, conversationID: id, runID: job.record.id) }
            else {
                do {
                    job.record = try await currentRecord(job.record.id)
                    if [.running, .waitingForUser].contains(job.record.journal.state) {
                        let journal = try await repository.transitionRun(id: job.record.id, expectedRevision: job.record.journal.revision,
                            token: job.token, event: .requestStop, now: clock.now())
                        job.record = replacingJournal(job.record, with: journal)
                    }
                    jobs[id] = job
                } catch { jobs[id]?.phase = .failed("Stop was requested, but its saved state could not be confirmed.") }
            }
        }
        release(id)
        await publish(id)
        if let runID { await driver.stop(runID: runID) }
    }

    public func history(conversationID: ConversationID) async throws -> [AgenticJobRecord] {
        // Reading a conversation is the first chance after a relaunch to close
        // a run no process is driving any more; otherwise its saved 'running'
        // state is shown as live work and blocks the bot. Best effort only.
        do { try await recoverAbandonedRuns(conversationID: conversationID) }
        catch { AgenticDiagnosticsLog.error("service", "abandoned-run recovery skipped: \(String(describing: error))") }
        return try await repository.agenticJobs(conversationID: conversationID, limit: 20)
    }

    public func shutdown() async {
        closing = true
        let conversations = Set(jobs.keys).union(databaseOwners).union(databaseWaiters.keys)
        for id in conversations { await stop(conversationID: id) }
        let tasks = jobs.values.compactMap(\.task) + drives.values
        drives.removeAll()
        for task in tasks { await task.value }
    }

    private func receive(_ event: AgenticJobDriverEvent, conversationID id: ConversationID, runID: RunID) async throws {
        await acquire(id)
        do {
            guard var job = jobs[id], job.record.id == runID, !terminal(job.record.journal.state) else { throw AgenticJobError.unavailable }
            if stoppedRuns.contains(runID) {
                switch event {
                case .worker(let worker):
                    guard job.record.state.workers.contains(where: { $0.id == worker.id }),
                          worker.lifecycle.isTerminal || worker.lifecycle == .stopping else { throw CancellationError() }
                case .inputAcknowledged: break
                default: throw CancellationError()
                }
            }
            job.record = try await currentRecord(runID)
            if job.record.journal.state == .starting {
                let journal = try await repository.transitionRun(id: runID, expectedRevision: job.record.journal.revision,
                    token: job.token, event: .started, now: clock.now())
                job.record = replacingJournal(job.record, with: journal)
            }
            switch event {
            case .conversation(let generation, let sessionID):
                let state = job.record.state
                job.record = try await saveState(.init(runID: runID, conversationGeneration: generation, sessionID: sessionID,
                    workers: state.workers, checkpointReferences: state.checkpointReferences), job: job)
                job.approval = nil; job.decisionInFlight = nil
            case .worker(let worker):
                let state = job.record.state
                var workers = state.workers
                if let index = workers.firstIndex(where: { $0.id == worker.id }) { workers[index] = worker }
                else { workers.append(worker) }
                job.record = try await saveState(.init(runID: runID, conversationGeneration: state.conversationGeneration,
                    sessionID: state.sessionID, workers: workers, checkpointReferences: state.checkpointReferences), job: job)
            case .checkpoint(let checkpoint):
                let state = job.record.state
                job.record = try await saveState(.init(runID: runID, conversationGeneration: state.conversationGeneration,
                    sessionID: state.sessionID, workers: state.workers, checkpointReferences: state.checkpointReferences + [checkpoint]), job: job)
            case .inputSubmitted(let messageID, let sequence), .inputAcknowledged(let messageID, let sequence):
                let submitted: Bool
                if case .inputSubmitted = event { submitted = true } else { submitted = false }
                let journal = try await repository.markRunInput(id: runID, expectedRevision: job.record.journal.revision,
                    token: job.token, messageID: messageID, sequence: sequence,
                    state: submitted ? .submitted : .acknowledged, now: clock.now())
                job.record = replacingJournal(job.record, with: journal)
                if !submitted { job.phase = sequence == job.nextInput - 1 ? .working : .changingDirection }
            case .text(let text):
                guard text.utf8.count <= 65_536 else { throw AgenticJobError.invalidLimit }
                job.text = text
            case .approval(let approval):
                guard approval.runID == runID, approval.conversationGeneration > 0,
                      approval.conversationGeneration == job.record.state.conversationGeneration,
                      approval.expiresAt.timeIntervalSince1970.isFinite, approval.expiresAt > clock.now(),
                      approval.title.utf8.count <= 256, approval.detail.utf8.count <= 8_192, approval.target.utf8.count <= 4_096,
                      job.approval == nil, job.decisionInFlight == nil else { throw AgenticJobError.staleGeneration }
                job.approval = approval; job.phase = .waitingForApproval
            case .approvalResolved(let approvalID):
                guard job.approval?.id == approvalID || job.decisionInFlight == approvalID else { throw AgenticJobError.staleGeneration }
                job.approval = nil; job.decisionInFlight = nil; job.phase = .working
            case .approvalCancelled(let approvalID):
                if job.approval?.id == approvalID || job.decisionInFlight == approvalID {
                    job.approval = nil; job.decisionInFlight = nil; job.phase = .working
                }
            case .observation(let line):
                guard !line.isEmpty, line.utf8.count <= AgenticJobProgress.maximumObservationBytes,
                      !line.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    throw AgenticJobError.invalidLimit
                }
                job.observations.append(line)
                if job.observations.count > AgenticJobProgress.maximumObservations { job.observations.removeFirst() }
            }
            if stoppedRuns.contains(runID) { job.phase = .stopping; job.approval = nil; job.decisionInFlight = nil }
            jobs[id] = job
            release(id)
        } catch {
            if !(error is CancellationError) { AgenticDiagnosticsLog.error("service", "driver event \(String(describing: event).prefix(40)) rejected: \(String(describing: error))") }
            if !(error is CancellationError), jobs[id]?.record.id == runID {
                failures[runID] = "The job's progress could not be saved or verified; it was stopped."
                stoppedRuns.insert(runID); jobs[id]?.phase = .failed(failures[runID]!)
                jobs[id]?.approval = nil; jobs[id]?.decisionInFlight = nil
            }
            release(id)
            Task { await driver.stop(runID: runID) }
            await publish(id)
            throw error
        }
        await publish(id)
    }

    /// A run this process is not driving, whose lease has lapsed and whose
    /// recorded worker process groups are all gone, was abandoned (for example
    /// by an earlier app instance that could not record its final state). It is
    /// marked interrupted so the bot can accept new work; nothing is resumed.
    private func recoverAbandonedRuns(conversationID id: ConversationID) async throws {
        let now = clock.now()
        for record in try await repository.agenticJobs(conversationID: id, limit: 8) {
            guard !terminal(record.journal.state), jobs[id]?.record.id != record.id,
                  record.journal.lease.map({ $0.expiresAt <= now }) ?? true else { continue }
            let liveWorker = record.state.workers.contains { worker in
                Self.processExists(worker.processID) || Self.processGroupExists(worker.processGroupID)
            }
            guard !liveWorker else { continue }
            let recovered = try await repository.recoverAbandonedExecutorRun(id: record.id, now: now)
            AgenticDiagnosticsLog.note("service", "recovered abandoned run \(record.id.rawValue.uuidString) as \(String(describing: recovered.state))")
        }
    }

    private static func processExists(_ processID: Int32?) -> Bool {
        guard let processID, processID > 1 else { return false }
        if Darwin.kill(processID, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func processGroupExists(_ processGroupID: Int32?) -> Bool {
        guard let processGroupID, processGroupID > 1, processGroupID != getpgrp() else { return false }
        if Darwin.kill(-processGroupID, 0) == 0 { return true }
        return errno == EPERM
    }

    private func saveState(_ state: AgenticJobState, job: Job) async throws -> AgenticJobRecord {
        try await repository.updateAgenticJob(runID: job.record.id, expectedRevision: job.record.revision,
            leaseToken: job.token, state: state, now: clock.now())
    }

    private func failAndStop(runID: RunID, conversationID: ConversationID, explanation: String) async {
        guard jobs[conversationID]?.record.id == runID else { return }
        failures[runID] = explanation; stoppedRuns.insert(runID)
        await stop(conversationID: conversationID)
    }

    private func finish(_ outcome: AgenticJobDriverOutcome, conversationID: ConversationID, runID: RunID) async {
        await acquire(conversationID)
        await finishLocked(outcome, conversationID: conversationID, runID: runID)
        release(conversationID)
        await publish(conversationID)
    }

    private func finishLocked(_ outcome: AgenticJobDriverOutcome, conversationID id: ConversationID, runID: RunID) async {
        guard var job = jobs[id], job.record.id == runID else { return }
        if case .failed(let explanation) = outcome, failures[runID] == nil {
            failures[runID] = String(explanation.prefix(2_000))
        }
        do {
            job.record = try await currentRecord(runID)
            if !terminal(job.record.journal.state) {
                var event = WorkRunEvent.interrupt
                var phase = AgenticJobPhase.stopped
                if let failure = failures[runID] { event = .fail; phase = .failed(failure) }
                else if !stoppedRuns.contains(runID), !closing {
                    switch outcome {
                    case .completed(let text):
                        let receipts = try await repository.runInputs(id: runID, limit: 100)
                        guard text.utf8.count <= 65_536, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              receipts.count == Int(job.nextInput - 1), receipts.allSatisfy({ $0.state == .acknowledged }),
                              job.approval == nil, job.decisionInFlight == nil,
                              job.record.state.workers.allSatisfy({ $0.lifecycle == .succeeded || $0.lifecycle == .stopped }) else {
                            throw AgenticJobError.invalidState
                        }
                        try await appendFinalReply(text, job: job)
                        job.text = text; event = .finish; phase = .completed
                    case .failed(let explanation):
                        event = .fail; phase = .failed(String(explanation.prefix(2_000)))
                    case .stopped: break
                    }
                }
                if stoppedRuns.contains(runID) || closing {
                    event = failures[runID] == nil ? .interrupt : .fail
                    phase = failures[runID].map(AgenticJobPhase.failed) ?? .stopped
                }
                let journal = try await repository.transitionRun(id: runID, expectedRevision: job.record.journal.revision,
                    token: job.token, event: event, now: clock.now())
                job.record = replacingJournal(job.record, with: journal); job.phase = phase
            } else {
                switch job.record.journal.state {
                case .succeeded: job.phase = .completed
                case .interrupted: job.phase = .stopped
                default: job.phase = .failed("The saved job ended with a failure.")
                }
            }
        } catch {
            AgenticDiagnosticsLog.error("service", "final state not confirmed: \(String(describing: error))")
            job.phase = .failed("The job ended, but its final saved state could not be confirmed.")
            // A failed final append or acceptance check must not leave a
            // misleading running/succeeded row when this lease can still close it.
            if let current = try? await currentRecord(runID), !terminal(current.journal.state), current.journal.lease?.token == job.token,
               let failed = try? await repository.transitionRun(id: runID, expectedRevision: current.journal.revision,
                    token: job.token, event: .fail, now: clock.now()) { job.record = replacingJournal(current, with: failed) }
        }
        job.approval = nil; job.decisionInFlight = nil; job.operation = nil; jobs[id] = job
    }

    private func appendFinalReply(_ text: String, job: Job) async throws {
        let id = job.record.journal.request.conversationID, messageID = MessageID(UUID()), partID = MessagePartID(UUID())
        for attempt in 0..<8 {
            let page = try await messages.page(conversationID: id, request: PageRequest(limit: 1))
            guard page.elements.count <= 1, page.elements.allSatisfy({ $0.conversationID == id && $0.sequence > 0 }) else {
                throw AgenticJobError.invalidState
            }
            let previous = page.elements.first?.sequence ?? 0
            guard previous < Int64.max else { throw AgenticJobError.invalidLimit }
            let now = clock.now()
            let message = try Message(id: messageID, conversationID: id, sequence: previous + 1,
                author: .teammate(job.record.journal.request.teammateID), deliveryState: .completed,
                parts: [MessagePart(id: partID, ordinal: 0, content: .text(text))], createdAt: now, updatedAt: now)
            do { try await messages.append(message, expectedPreviousSequence: previous); return }
            catch RepositoryError.sequenceConflict where attempt < 7 { continue }
        }
        throw AgenticJobError.unavailable
    }

    private func currentRecord(_ runID: RunID) async throws -> AgenticJobRecord {
        guard let record = try await repository.agenticJob(runID: runID), record.id == runID,
              record.journal.origin == .executor else { throw AgenticJobError.unavailable }
        return record
    }
    private func replacingJournal(_ record: AgenticJobRecord, with journal: RunJournalRecord) -> AgenticJobRecord {
        AgenticJobRecord(journal: journal, revision: record.revision, state: record.state, updatedAt: record.updatedAt)
    }
    private func terminal(_ state: WorkRunState) -> Bool { [.succeeded, .failed, .interrupted].contains(state) }
    private func matchesSavedMessage(_ saved: Message, _ supplied: Message) -> Bool {
        saved.id == supplied.id && saved.conversationID == supplied.conversationID && saved.sequence == supplied.sequence
            && saved.author == supplied.author && saved.outputClass == supplied.outputClass
            && saved.deliveryState == supplied.deliveryState && saved.parts == supplied.parts
            && saved.createdAt.timeIntervalSince1970 == supplied.createdAt.timeIntervalSince1970
            && saved.updatedAt.timeIntervalSince1970 == supplied.updatedAt.timeIntervalSince1970
    }
    private func exactText(_ message: Message) throws -> String {
        var text = ""
        for part in message.parts {
            guard case .text(let value) = part.content else { throw AgenticJobError.invalidState }
            text += value
        }
        return text
    }
    private func checkPreparation(_ id: ConversationID, epoch: UInt64) throws {
        try Task.checkCancellation()
        guard !closing, epochs[id, default: 0] == epoch else { throw CancellationError() }
    }
    private func permitted(_ id: ConversationID, runID: RunID, epoch: UInt64) -> Bool {
        !closing && epochs[id, default: 0] == epoch && jobs[id]?.record.id == runID && !stoppedRuns.contains(runID)
    }
    private func decisionPermitted(_ approval: AgenticJobApproval) -> Bool {
        !closing && !stoppedRuns.contains(approval.runID) && jobs.values.contains(where: {
            $0.record.id == approval.runID && $0.decisionInFlight == approval.id
                && $0.record.state.conversationGeneration == approval.conversationGeneration
        })
    }
    private func acquire(_ id: ConversationID) async {
        if databaseOwners.insert(id).inserted { return }
        await withCheckedContinuation { databaseWaiters[id, default: []].append($0) }
    }
    private func release(_ id: ConversationID) {
        if var waiters = databaseWaiters[id], !waiters.isEmpty {
            let next = waiters.removeFirst(); databaseWaiters[id] = waiters.isEmpty ? nil : waiters
            next.resume()
        } else { databaseOwners.remove(id) }
    }
    private func publish(_ id: ConversationID) async {
        guard let job = jobs[id] else { return }
        await job.progress(AgenticJobProgress(runID: job.record.id, conversationID: id, phase: job.phase,
            text: job.text, approval: job.approval, conversationGeneration: job.record.state.conversationGeneration,
            observations: job.observations))
    }
}
