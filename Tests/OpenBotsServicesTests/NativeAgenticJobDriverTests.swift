import Darwin
import Foundation
import OpenBotsDomain
import OpenBotsExecutionRules
import OpenBotsSecurity
import Testing
@testable import OpenBotsAgenticRuntime
@testable import OpenBotsServices

@Suite("Native driver over a synthetic process peer, never a live provider", .serialized, .timeLimit(.minutes(1)))
struct NativeAgenticJobDriverTests {
    @Test("Initial native consent precedes preparation, and denial or a late decision launches nothing")
    func initialConsent() async throws {
        try await withNativePeer { harness in
            let consent = try await harness.approval(title: "Start this tool job?")
            #expect(await harness.preparation.calls.isEmpty)
            #expect(await harness.preparation.reportCalls == 0)
            try await harness.driver.decide(approvalID: consent.id, allow: false, runID: harness.request.runID,
                conversationGeneration: consent.conversationGeneration)
            guard case .stopped = await harness.task.value else { Issue.record("Denied start must be stopped"); return }
            await #expect(throws: (any Error).self) {
                try await harness.driver.decide(approvalID: consent.id, allow: true, runID: harness.request.runID,
                    conversationGeneration: consent.conversationGeneration)
            }
            #expect(await harness.preparation.calls.isEmpty)
        }
    }

    @Test("One exact command approval creates the synthetic report and cleanup precedes completed outcome")
    func processBackedReport() async throws {
        try await withNativePeer { harness in
            try await harness.allowStart()
            let command = try await harness.approval(title: "Allow this command?")
            #expect(command.detail == "fixture-report --sample sample.csv --output report.md --step 1")
            #expect(command.target == harness.preparation.workerDirectory.path)
            #expect(!FileManager.default.fileExists(atPath: harness.preparation.reportURL.path))
            await #expect(throws: NativeAgenticJobFailure.expiredApproval) {
                try await harness.driver.decide(approvalID: UUID(), allow: true, runID: harness.request.runID,
                    conversationGeneration: command.conversationGeneration)
            }
            #expect(!FileManager.default.fileExists(atPath: harness.preparation.reportURL.path))
            try await harness.driver.decide(approvalID: command.id, allow: true, runID: harness.request.runID,
                conversationGeneration: command.conversationGeneration)
            guard case .completed(let text) = await harness.task.value else { Issue.record("Expected completed synthetic report"); return }
            #expect(text == "Synthetic report: rows=3, total=139.\n")
            #expect(try String(contentsOf: harness.preparation.reportURL, encoding: .utf8) == text)
            #expect(await harness.preparation.reportCalls == 1)
            let events = await harness.log.events
            let checkpoints = events.compactMap { if case .checkpoint(let value) = $0 { return value }; return nil }
            #expect(checkpoints.count == 1)
            #expect(checkpoints.first?.sha256 == PayloadDigest.sha256(of: Data(text.utf8)).rawValue)
            #expect(events.contains { if case .worker(let worker) = $0 { return worker.lifecycle == .succeeded }; return false })
            await harness.assertObservedGroupsGone()
        }
    }

    @Test("Correction preserves the worker PID and completed fixture checkpoint, then only its new approval can run")
    func correctionPreservesWorker() async throws {
        try await withNativePeer(mode: "redirect") { harness in
            try await harness.allowStart()
            let old = try await harness.approval(title: "Allow this command?")
            let worker = try await harness.runningWorker()
            let checkpoint = try Data(contentsOf: harness.preparation.checkpointURL)
            let correction = try SteeringInput(messageID: MessageID(UUID()), sequence: 2,
                text: "Exclude test rows.", submittedAt: Date())
            try await harness.driver.steer(correction, runID: harness.request.runID)
            let new = try await harness.approval(title: "Allow this command?", generation: 2)
            #expect(new.id != old.id && new.detail.hasSuffix("--step 2"))
            await #expect(throws: NativeAgenticJobFailure.expiredApproval) {
                try await harness.driver.decide(approvalID: old.id, allow: true, runID: harness.request.runID,
                    conversationGeneration: old.conversationGeneration)
            }
            #expect(try await harness.runningWorker() == worker)
            #expect(try Data(contentsOf: harness.preparation.checkpointURL) == checkpoint)
            #expect(kill(try #require(worker.processID), 0) == 0)
            try await harness.driver.decide(approvalID: new.id, allow: true, runID: harness.request.runID,
                conversationGeneration: new.conversationGeneration)
            guard case .completed(let text) = await harness.task.value else { Issue.record("Expected corrected synthetic report"); return }
            #expect(text == "Synthetic report: rows=2, total=40.\n")
            #expect(await harness.preparation.calls.filter { $0 == .worker }.count == 1)
            #expect(!FileManager.default.fileExists(atPath: harness.preparation.obsoleteApprovalURL.path))
        }
    }

    @Test("Correction while approvalResolved is suspended cannot dispatch the removed obsolete command")
    func approvalResolutionRace() async throws {
        try await withNativePeer(mode: "redirect") { harness in
            try await harness.allowStart()
            let old = try await harness.approval(title: "Allow this command?")
            await harness.log.holdResolution(of: old.id)
            let decision = Task { try await harness.driver.decide(approvalID: old.id, allow: true,
                runID: harness.request.runID, conversationGeneration: old.conversationGeneration) }
            try await waitForNativeCondition { await harness.log.resolutionSuspended }
            try await harness.driver.steer(SteeringInput(messageID: MessageID(UUID()), sequence: 2,
                text: "Exclude test rows.", submittedAt: Date()), runID: harness.request.runID)
            // Like the real CLI, the peer holds the correction until the pending
            // command is answered; the suspended decision must resolve as a
            // denial before the corrected generation can ask again.
            await harness.log.releaseResolution()
            switch await decision.result {
            case .success: Issue.record("The removed old decision must not dispatch after the generation changes")
            case .failure: break
            }
            let current = try await harness.approval(title: "Allow this command?", generation: 2)
            #expect(!FileManager.default.fileExists(atPath: harness.preparation.obsoleteApprovalURL.path))
            try await harness.driver.decide(approvalID: current.id, allow: true, runID: harness.request.runID,
                conversationGeneration: current.conversationGeneration)
            guard case .completed(let text) = await harness.task.value else { Issue.record("Current approval should remain usable"); return }
            #expect(text == "Synthetic report: rows=2, total=40.\n")
            #expect(!FileManager.default.fileExists(atPath: harness.preparation.obsoleteApprovalURL.path))
        }
    }

    @Test("Stop during delayed admission rejects the late plan, and stopped-run dispatch cannot start again")
    func latePreparationAndStop() async throws {
        try await withNativePeer(holdPreparation: true) { harness in
            try await harness.allowStart()
            try await waitForNativeCondition { await harness.preparation.suspended }
            await harness.driver.stop(runID: harness.request.runID)
            guard case .stopped = await harness.task.value else { Issue.record("Expected stopped pending startup"); return }
            await harness.preparation.release()
            try await waitForNativeCondition { await harness.preparation.returned }
            // The fake intentionally ignores cancellation while delayed. Give
            // the already-enqueued late result one bounded scheduling window.
            try await Task.sleep(for: .milliseconds(50))
            #expect(!FileManager.default.fileExists(atPath: harness.preparation.workerDirectory.appending(path: "fixture-started").path))
            guard case .stopped = await harness.driver.run(harness.request, event: { _ in }) else {
                Issue.record("Stop must invalidate a later run call with the same identity"); return
            }
            #expect(await harness.preparation.calls == [.worker])
        }
    }

    @Test("Revoking then re-enabling access stops the current job and cannot revive a pending approval")
    func accessRevocation() async throws {
        try await withNativePeer { harness in
            try await harness.allowStart()
            let command = try await harness.approval(title: "Allow this command?")
            await harness.access.setBotEnabled(false, teammateID: harness.request.teammateID)
            await harness.access.setBotEnabled(true, teammateID: harness.request.teammateID)
            guard case .stopped = await harness.task.value else { Issue.record("Access revision must stop the old job"); return }
            await #expect(throws: (any Error).self) {
                try await harness.driver.decide(approvalID: command.id, allow: true, runID: harness.request.runID,
                    conversationGeneration: command.conversationGeneration)
            }
            #expect(!FileManager.default.fileExists(atPath: harness.preparation.reportURL.path))
            #expect(await harness.preparation.reportCalls == 0)
            await harness.assertObservedGroupsGone()
        }
    }

    @Test("Unconfirmed cleanup stays failed and blocks a new job for that bot after actual fixture teardown")
    func uncertainCleanupCannotBecomeSuccess() async throws {
        try await withNativePeer(cleanupConfirmed: false) { harness in
            try await harness.allowStart()
            let command = try await harness.approval(title: "Allow this command?")
            try await harness.driver.decide(approvalID: command.id, allow: true, runID: harness.request.runID,
                conversationGeneration: command.conversationGeneration)
            guard case .failed = await harness.task.value else { Issue.record("Missing cleanup evidence cannot become success"); return }
            #expect(await harness.log.events.contains { if case .worker(let value) = $0 { return value.lifecycle == .outcomeUnknown }; return false })
            let repeated = try WorkRequest(runID: OpenBotsDomain.RunID(UUID()), teammateID: harness.request.teammateID,
                conversationID: harness.request.conversationID, initiatingMessageID: harness.request.initiatingMessageID,
                profileRevision: 1, initialInput: harness.request.initialInput, submittedAt: Date())
            let before = await harness.preparation.calls.count
            guard case .failed = await harness.driver.run(repeated, event: { _ in }) else { Issue.record("Unresolved cleanup must block another job"); return }
            #expect(await harness.preparation.calls.count == before)
            await harness.assertObservedGroupsGone()
        }
    }

    @Test("A granted web search is allowed without a card, listed for the user, and given only to the worker's plan")
    func grantedWebSearchIsListed() async throws {
        try await withNativePeer(mode: "websearch", web: [.search]) { harness in
            let start = try await harness.approval(title: "Start this tool job?")
            #expect(start.detail.contains("Web search is on"))
            #expect(!start.detail.contains("Web fetch"))
            try await harness.driver.decide(approvalID: start.id, allow: true, runID: harness.request.runID,
                conversationGeneration: start.conversationGeneration)
            let command = try await harness.approval(title: "Allow this command?")
            let events = await harness.log.events
            #expect(events.contains { if case .observation(let line) = $0 { return line == "Web search: sample totals" }; return false })
            let titles = events.compactMap { if case .approval(let value) = $0 { return value.title }; return nil }
            #expect(Set(titles) == ["Start this tool job?", "Allow this command?"])
            #expect(try String(contentsOf: harness.preparation.webMarkerURL, encoding: .utf8) == "sample totals")
            try await harness.driver.decide(approvalID: command.id, allow: true, runID: harness.request.runID,
                conversationGeneration: command.conversationGeneration)
            guard case .completed = await harness.task.value else { Issue.record("Expected the report after the search"); return }
            #expect(await harness.preparation.webCapabilityCalls == [[.search], []])
        }
    }

    @Test("Without its grant the same web search closes the job before anything runs")
    func ungrantedWebSearchStopsTheJob() async throws {
        try await withNativePeer(mode: "websearch") { harness in
            let start = try await harness.approval(title: "Start this tool job?")
            #expect(start.detail.contains("It has no web access."))
            try await harness.driver.decide(approvalID: start.id, allow: true, runID: harness.request.runID,
                conversationGeneration: start.conversationGeneration)
            guard case .failed(let message) = await harness.task.value else { Issue.record("An ungranted web tool must fail the job"); return }
            #expect(message.contains("protocolRejected"))
            #expect(!FileManager.default.fileExists(atPath: harness.preparation.reportURL.path))
            #expect(!FileManager.default.fileExists(atPath: harness.preparation.webMarkerURL.path))
            #expect(!(await harness.log.events).contains { if case .observation = $0 { return true }; return false })
            #expect(await harness.preparation.webCapabilityCalls.first == [])
            await harness.assertObservedGroupsGone()
        }
    }

    @Test("Turning a granted web switch off mid-job stops the job and cannot revive its pending approval")
    func webRevocationStopsTheJob() async throws {
        try await withNativePeer(web: [.fetch]) { harness in
            let start = try await harness.approval(title: "Start this tool job?")
            #expect(start.detail.contains("Web fetch is on"))
            try await harness.driver.decide(approvalID: start.id, allow: true, runID: harness.request.runID,
                conversationGeneration: start.conversationGeneration)
            let command = try await harness.approval(title: "Allow this command?")
            await harness.access.setAppEnabled(false, capability: .web(.fetch))
            guard case .stopped = await harness.task.value else { Issue.record("A web switch change must stop the admitted job"); return }
            await #expect(throws: (any Error).self) {
                try await harness.driver.decide(approvalID: command.id, allow: true, runID: harness.request.runID,
                    conversationGeneration: command.conversationGeneration)
            }
            #expect(!FileManager.default.fileExists(atPath: harness.preparation.reportURL.path))
            #expect(await harness.preparation.webCapabilityCalls.first == [.fetch])
            await harness.assertObservedGroupsGone()
        }
    }

    private func withNativePeer(mode: String = "report", holdPreparation: Bool = false, cleanupConfirmed: Bool = true,
                                web: Set<AgenticWebCapability> = [],
                                body: (NativePeerHarness) async throws -> Void) async throws {
        let harness = try await NativePeerHarness.create(mode: mode, holdPreparation: holdPreparation,
            cleanupConfirmed: cleanupConfirmed, web: web)
        do { try await body(harness) }
        catch { await harness.close(); throw error }
        await harness.close()
    }
}

private enum NativePeerTestFailure: Error { case timedOut, unavailable }

private func waitForNativeCondition(_ condition: @escaping @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw NativePeerTestFailure.timedOut }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private actor NativePeerEvents {
    private(set) var events: [AgenticJobDriverEvent] = []
    private(set) var terminal: String?
    func ended(_ outcome: AgenticJobDriverOutcome) { terminal = String(describing: outcome) }
    func diagnostic() -> String { "outcome=\(terminal ?? "pending"); events=\(events)" }
    private var heldApproval: UUID?
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var resolutionSuspended = false
    func holdResolution(of id: UUID) { heldApproval = id }
    func record(_ event: AgenticJobDriverEvent) async {
        events.append(event)
        if case .approvalResolved(let id) = event, heldApproval == id {
            resolutionSuspended = true
            await withCheckedContinuation { waiter = $0 }
        }
    }
    func releaseResolution() { heldApproval = nil; waiter?.resume(); waiter = nil }
    func approval(title: String, generation: UInt64?) -> AgenticJobApproval? {
        events.compactMap { if case .approval(let value) = $0 { return value }; return nil }
            .first { $0.title == title && (generation == nil || $0.conversationGeneration == generation) }
    }
    func runningWorker() -> AgenticJobWorker? {
        events.compactMap { if case .worker(let value) = $0, value.lifecycle == .running { return value }; return nil }.first
    }
}

/// Only this injected test preparer can construct the synthetic plan. Its fake
/// signature metadata never passes native admission and is not live authority.
private actor SyntheticNativePreparation: AgenticJobPreparing {
    nonisolated let root: URL
    nonisolated var workerDirectory: URL { root.appending(path: "worker/work") }
    nonisolated var reportURL: URL { workerDirectory.appending(path: "report.md") }
    nonisolated var checkpointURL: URL { workerDirectory.appending(path: "fixture-checkpoint.txt") }
    nonisolated var obsoleteApprovalURL: URL { workerDirectory.appending(path: "obsolete-approval-used") }
    nonisolated var webMarkerURL: URL { workerDirectory.appending(path: "web-search-used.txt") }
    private let mode: String
    private let holdPreparation: Bool
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var calls: [FirstToolJobProcessRole] = []
    private(set) var webCapabilityCalls: [Set<AgenticWebCapability>] = []
    private(set) var paths: [AgenticProbePaths] = []
    private(set) var reportCalls = 0
    private(set) var suspended = false
    private(set) var returned = false

    init(root: URL, mode: String, holdPreparation: Bool) { self.root = root; self.mode = mode; self.holdPreparation = holdPreparation }
    func prepare(request: WorkRequest, role: FirstToolJobProcessRole, sessionID: UUID,
                 webCapabilities: Set<AgenticWebCapability>) async throws -> FirstToolJobLaunchPlan {
        calls.append(role)
        webCapabilityCalls.append(webCapabilities)
        let processRoot = root.appending(path: role == .worker ? "worker" : "conversation-\(sessionID.uuidString.lowercased())")
        let value = try AgenticProbePaths(root: processRoot, configurationDirectory: root.appending(path: "fictional-profile"),
            homeDirectory: root.appending(path: "fictional-home"), claudeExecutable: URL(fileURLWithPath: "/usr/bin/python3"))
        try FileManager.default.createDirectory(at: value.workingDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: value.temporaryDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if role == .worker {
            try Data("id,environment,amount\n1,production,10\n2,test,99\n3,production,30\n".utf8).write(to: workerDirectory.appending(path: "sample.csv"))
            try Data("Fixed completed fixture validation, unchanged across redirect.\n".utf8).write(to: checkpointURL)
        }
        paths.append(value)
        let admission = FirstToolJobAdmissionReceipt(installation: .init(requestedPath: "/usr/bin/python3",
            resolvedPath: "/usr/bin/python3", versionFilename: "synthetic-peer", sha256: String(repeating: "a", count: 64),
            signature: .init(identifier: "synthetic", teamIdentifier: "synthetic"), fileIdentity: .init(device: 1, inode: 1, byteCount: 1_024)),
            profile: .init(applicationSupportPath: root.path, profilePath: root.path, markerPath: root.path,
                installationID: UUID(), rootID: UUID(), bundleIdentifier: "synthetic", markerSchemaVersion: 1, role: "synthetic"), checkedAt: Date())
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/native-agentic-peer.py")
        let granted = role == .worker ? webCapabilities : []
        let tools = (role == .worker ? ["Bash"] : []) + AgenticWebCapability.toolNames(granted)
        let plan = FirstToolJobLaunchPlan(admission: admission, paths: value, role: role,
            teammateID: OpenBotsExecutionRules.TeammateID(request.teammateID.rawValue),
            runID: OpenBotsExecutionRules.RunID(request.runID.rawValue), sessionID: sessionID, model: "synthetic",
            arguments: ["-u", script.path, role.rawValue, sessionID.uuidString.lowercased(), mode, tools.joined(separator: ",")],
            environment: ["PATH": "/usr/bin:/bin", "LANG": "C", "PYTHONDONTWRITEBYTECODE": "1"],
            settingsJSON: Data(), settingsSHA256: "synthetic", mcpJSON: Data(), mcpSHA256: "synthetic",
            limits: .init(maximumWallTimeSeconds: 20, startupTimeoutSeconds: 5), webCapabilities: granted)
        if holdPreparation, role == .worker {
            suspended = true
            await withCheckedContinuation { waiter = $0 }
        }
        returned = true
        return plan
    }
    func release() { waiter?.resume(); waiter = nil }
    func report(runID: OpenBotsDomain.RunID) throws -> AgenticJobReport {
        reportCalls += 1
        let bytes = try Data(contentsOf: reportURL)
        return AgenticJobReport(text: String(decoding: bytes, as: UTF8.self),
            sha256: PayloadDigest.sha256(of: bytes).rawValue, sourceURL: reportURL)
    }
}

private struct NativePeerHarness: Sendable {
    let root: URL
    let preparation: SyntheticNativePreparation
    let access: AgenticJobAccessStore
    let driver: NativeAgenticJobDriver
    let request: WorkRequest
    let log: NativePeerEvents
    let task: Task<AgenticJobDriverOutcome, Never>

    static func create(mode: String, holdPreparation: Bool, cleanupConfirmed: Bool,
                       web: Set<AgenticWebCapability> = []) async throws -> Self {
        let root = URL(fileURLWithPath: "/private/tmp/OpenBotsNativePeer-\(UUID()).noindex")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let preparation = SyntheticNativePreparation(root: root, mode: mode, holdPreparation: holdPreparation)
        let access = AgenticJobAccessStore()
        let teammate = OpenBotsDomain.TeammateID(UUID()), messageID = MessageID(UUID())
        let request = try WorkRequest(runID: OpenBotsDomain.RunID(UUID()), teammateID: teammate,
            conversationID: ConversationID(UUID()), initiatingMessageID: messageID, profileRevision: 1,
            initialInput: WorkInput(messageID: messageID, sequence: 1, text: "Make a report of all sample rows."), submittedAt: Date())
        await access.setAppEnabled(true)
        await access.setBotEnabled(true, teammateID: teammate)
        for capability in web {
            await access.setAppEnabled(true, capability: .web(capability))
            await access.setBotEnabled(true, capability: .web(capability), teammateID: teammate)
        }
        let driver = NativeAgenticJobDriver(preparation: preparation, access: access, cleanupConfirmed: { $0 && cleanupConfirmed })
        let log = NativePeerEvents()
        let task = Task {
            let result = await driver.run(request) { await log.record($0) }
            await log.ended(result)
            return result
        }
        return Self(root: root, preparation: preparation, access: access, driver: driver, request: request, log: log, task: task)
    }
    func approval(title: String, generation: UInt64? = nil) async throws -> AgenticJobApproval {
        try await waitForNativeCondition {
            if await log.approval(title: title, generation: generation) != nil { return true }
            return await log.terminal != nil
        }
        if await log.approval(title: title, generation: generation) == nil {
            Issue.record("Expected approval was never reached: \(await log.diagnostic())")
            throw NativePeerTestFailure.unavailable
        }
        return try #require(await log.approval(title: title, generation: generation))
    }
    func runningWorker() async throws -> AgenticJobWorker {
        try await waitForNativeCondition { await log.runningWorker() != nil }
        return try #require(await log.runningWorker())
    }
    func allowStart() async throws {
        let initial = try await approval(title: "Start this tool job?")
        try await driver.decide(approvalID: initial.id, allow: true, runID: request.runID,
            conversationGeneration: initial.conversationGeneration)
    }
    func assertObservedGroupsGone() async {
        for path in await preparation.paths {
            let marker = path.workingDirectory.appending(path: "fixture-started")
            if let value = try? String(contentsOf: marker, encoding: .utf8), let pid = Int32(value) {
                #expect(kill(-pid, 0) == -1 && errno == ESRCH)
            }
        }
    }
    func close() async {
        await driver.stop(runID: request.runID)
        await log.releaseResolution()
        await preparation.release()
        _ = await task.value
        await assertObservedGroupsGone()
        try? FileManager.default.removeItem(at: root)
    }
}
