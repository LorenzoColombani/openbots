import ClaudeRuntimeProbeCore
import Darwin
import Foundation
import OpenBotsExecutionRules
import OpenBotsSecurity
import Testing
@testable import OpenBotsAgenticRuntime

@Suite("Admitted process adapter over synthetic protocol peers")
struct FirstToolJobProcessTests {
    @Test("Failed-result summaries prefer explicit errors, redact complete input, and remain display-only",
          arguments: ["provider-errors", "provider-result", "provider-empty-errors", "provider-secrets", "provider-token-patterns", "provider-labelled-value", "provider-long-identifier", "provider-display-bound"])
    func providerFailureSummary(_ mode: String) async throws {
        try await withPeer(mode: mode, role: .worker) { fixture, process in
            try await process.start(initialInput: "Synthetic input")
            let events = await collected(process)
            let summaries = events.compactMap { event -> String? in
                if case .providerFailureSummary(let value) = event { return value }; return nil
            }
            #expect(summaries.count == 1)
            let summary = try #require(summaries.first)
            #expect(!summary.isEmpty && summary.count <= 512)
            #expect(!summary.unicodeScalars.contains {
                $0.properties.generalCategory == .control || $0.properties.generalCategory == .format
            })
            for forbidden in ["person@example.invalid", "object@example.invalid", "https://", "urlSecret", "bearerSecret",
                              "keySecret", "tokenSecret", "pwdSecret", "API_KEY", "Bearer", "token:", "password=",
                              "sk-ant-shortKey", "ghp_shortKey", "xoxb-shortKey", "AIzaSHORTKEY",
                              "anthropicApiKey", "tinyValue",
                              "RAW_FALLBACK", "RAW_ACCOUNT", "RAW_USAGE", "RAW_STDERR"] {
                #expect(!summary.contains(forbidden), "Unexpected unredacted fixture marker")
            }
            switch mode {
            case "provider-errors": #expect(summary == "The selected model is unavailable. Try again later.")
            case "provider-result", "provider-empty-errors": #expect(summary == "The request exceeded the provider limit.")
            case "provider-secrets":
                #expect(summary.contains("Subscription refused"))
                #expect(summary.contains("[redacted]"))
            case "provider-token-patterns", "provider-labelled-value":
                #expect(summary.contains("Provider refused"))
                #expect(summary.contains("[redacted]"))
            case "provider-long-identifier":
                // This suffix occurs past raw character 512. It survives only
                // when the complete opaque value is redacted before clipping.
                #expect(summary.contains("Retry in ten minutes."))
                #expect(!summary.contains(String(repeating: "a", count: 24)))
            default: #expect(summary.count == 512 && summary.hasSuffix("…"))
            }
            #expect(events.contains(.failed(.providerFailure)))
            #expect(!events.contains { event in
                switch event { case .toolRequested, .completed: true; default: false }
            })
            #expect(!FileManager.default.fileExists(atPath: fixture.marker.path))
            let detailIndex = try #require(events.firstIndex { if case .providerFailureSummary = $0 { return true }; return false })
            let failureIndex = try #require(events.firstIndex(of: .failed(.providerFailure)))
            #expect(detailIndex < failureIndex)
            assertClean(events)
        }
    }

    @Test("Missing, malformed, oversized and control-bearing failed-result details remain generic",
          arguments: ["provider-absent", "provider-malformed-errors", "provider-malformed-result", "provider-many-errors",
                      "provider-oversized-errors", "provider-oversized-result", "provider-controls", "provider-empty"])
    func unusableProviderFailureDetails(_ mode: String) async throws {
        try await withPeer(mode: mode, role: .worker) { fixture, process in
            try await process.start(initialInput: "Synthetic input")
            let events = await collected(process)
            #expect(events.contains(.failed(.providerFailure)))
            #expect(!events.contains { event in
                switch event { case .providerFailureSummary, .toolRequested, .completed: true; default: false }
            })
            #expect(!String(describing: events).contains("RAW_"))
            #expect(!FileManager.default.fileExists(atPath: fixture.marker.path))
            assertClean(events)
        }
    }

    @Test("Construction is inert, denial launches nothing, and Start cannot be repeated")
    func admissionIsRequired() async throws {
        let calls = ProcessAdmissionCounter()
        let inert = FirstToolJobProcess(policyGeneration: 1, ledger: ApprovalLedger()) {
            await calls.record()
            throw FirstToolJobProcessFailure.admissionDenied
        }
        #expect(await calls.count == 0)
        await #expect(throws: FirstToolJobProcessFailure.notReady) { try await inert.lifetimeRegistration() }
        #expect(await inert.stop() == nil)
        #expect(await calls.count == 0)

        let denied = FirstToolJobProcess(policyGeneration: 1, ledger: ApprovalLedger()) {
            await calls.record()
            throw FirstToolJobProcessFailure.admissionDenied
        }
        try await denied.start(initialInput: "Synthetic input")
        let events = await collected(denied)
        #expect(events == [.stopped(nil), .failed(.admissionDenied)])
        await #expect(throws: FirstToolJobProcessFailure.notReady) { try await denied.lifetimeRegistration() }
        #expect(await calls.count == 1)
        await #expect(throws: FirstToolJobProcessFailure.alreadyStarted) {
            try await denied.start(initialInput: "No second launch")
        }
    }

    @Test("Stop during pending admission prevents a late admission result from launching")
    func stopPendingAdmission() async throws {
        let fixture = try ProcessPeerFixture(mode: "complete", role: .conversation,
            limits: .init(maximumWallTimeSeconds: 4, startupTimeoutSeconds: 2))
        defer { fixture.remove() }
        let gate = ProcessAdmissionGate(), plan = fixture.plan
        let process = FirstToolJobProcess(policyGeneration: 7, ledger: ApprovalLedger()) {
            await gate.wait()
            return plan
        }
        try await process.start(initialInput: "Synthetic input")
        let deadline = ContinuousClock.now + .seconds(1)
        while !(await gate.entered), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(await gate.entered)
        #expect(await process.stop() == nil)
        await gate.release()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await collected(process) == [.stopped(nil)])
        #expect(!FileManager.default.fileExists(atPath: plan.paths.workingDirectory.appending(path: "fixture-started").path))
        await #expect(throws: FirstToolJobProcessFailure.notReady) { try await process.lifetimeRegistration() }
    }

    @Test("Conversation text preserves bytes, submissions precede acknowledgements, and cleanup precedes success")
    func conversationRoundTrip() async throws {
        try await withPeer(mode: "complete", role: .conversation) { _, process in
            let id = UUID()
            try await process.start(initialInput: "  Keep café rows.\nExactly this.  ", id: id)
            let events = await collected(process)
            let submitted = try #require(events.firstIndex(of: .inputSubmitted(id)))
            let acknowledged = try #require(events.firstIndex(of: .inputAcknowledged(id)))
            #expect(submitted < acknowledged)
            #expect(events.contains(.assistantText("Visible fixture reply: café")))
            #expect(!events.contains(.assistantText("hidden reasoning")))
            #expect(!events.contains { if case .providerFailureSummary = $0 { return true }; return false })
            let completed = try #require(events.firstIndex(of: .completed(resultText: "fixture complete")))
            let stopped = try #require(events.firstIndex { if case .stopped = $0 { return true }; return false })
            #expect(stopped < completed)
            assertClean(events)
            // The native listener may consume its buffered started event only
            // after this short conversation has finished and cleaned up.
            let registration = try await process.lifetimeRegistration()
            let started = events.compactMap { event -> (Int32, Int32)? in
                if case .started(_, let pid, let group) = event { return (pid, group) }; return nil
            }
            #expect(started.count == 1)
            #expect(registration.processID == started.first?.0)
            #expect(registration.processGroupID == started.first?.1)
            #expect(kill(-registration.processGroupID, 0) == -1 && errno == ESRCH)
        }
    }

    @Test("A worker action uses the actual approval ledger before the fixture creates its output", arguments: [false, true])
    func workerApproval(_ deny: Bool) async throws {
        let ledger = ApprovalLedger()
        try await withPeer(mode: "tool", role: .worker, ledger: ledger) { fixture, process in
            try await process.start(initialInput: "Create the fixture output")
            var events: [FirstToolJobProcessEvent] = []
            for await event in process.events {
                events.append(event)
                if case .toolRequested(let invocation) = event {
                    #expect(!FileManager.default.fileExists(atPath: fixture.marker.path))
                    if deny { try await process.deny(requestID: invocation.requestID) }
                    else {
                        let action = try fixture.action(invocation)
                        let receipt = try ledger.issue(receiptID: ApprovalReceiptID(UUID()), for: action,
                            issuedAt: fixture.now, expiresAt: fixture.now.addingTimeInterval(10))
                        try await process.approve(requestID: invocation.requestID, action: action, receipt: receipt,
                            currentPolicyGeneration: 7, now: fixture.now)
                        #expect(throws: BrokerPolicyError.receiptAlreadyConsumed) {
                            try ledger.consume(receipt, for: action, at: fixture.now)
                        }
                    }
                }
            }
            #expect(FileManager.default.fileExists(atPath: fixture.marker.path) == !deny)
            #expect(events.contains(.toolResult("fixture-tool", failed: deny)))
            #expect(events.contains(deny ? .failed(.providerFailure) : .completed(resultText: "fixture complete")))
            assertClean(events)
        }
    }

    @Test("The permission callback that follows an approved hook is answered from that approval, without a second prompt")
    func workerApprovalPair() async throws {
        let ledger = ApprovalLedger()
        try await withPeer(mode: "pair", role: .worker, ledger: ledger) { fixture, process in
            try await process.start(initialInput: "Create the fixture output")
            var events: [FirstToolJobProcessEvent] = []
            var requests = 0
            for await event in process.events {
                events.append(event)
                if case .toolRequested(let invocation) = event {
                    requests += 1
                    let action = try fixture.action(invocation)
                    let receipt = try ledger.issue(receiptID: ApprovalReceiptID(UUID()), for: action,
                        issuedAt: fixture.now, expiresAt: fixture.now.addingTimeInterval(10))
                    try await process.approve(requestID: invocation.requestID, action: action, receipt: receipt,
                        currentPolicyGeneration: 7, now: fixture.now)
                }
            }
            #expect(requests == 1)
            #expect(FileManager.default.fileExists(atPath: fixture.marker.path))
            #expect(events.contains(.toolResult("fixture-tool", failed: false)))
            #expect(events.contains(.completed(resultText: "fixture complete")))
            assertClean(events)
        }
    }

    @Test("A correction sent during the first turn survives that turn's result and is answered in the next")
    func correctionAcrossTurns() async throws {
        let ledger = ApprovalLedger()
        try await withPeer(mode: "correction", role: .worker, ledger: ledger) { fixture, process in
            try await process.start(initialInput: "Create the fixture output")
            var events: [FirstToolJobProcessEvent] = []
            let correctionID = UUID()
            for await event in process.events {
                events.append(event)
                if case .toolRequested(let invocation) = event {
                    let action = try fixture.action(invocation)
                    let receipt = try ledger.issue(receiptID: ApprovalReceiptID(UUID()), for: action,
                        issuedAt: fixture.now, expiresAt: fixture.now.addingTimeInterval(10))
                    try await process.approve(requestID: invocation.requestID, action: action, receipt: receipt,
                        currentPolicyGeneration: 7, now: fixture.now)
                    try await process.sendInput(id: correctionID, text: "Exclude rows marked test.")
                }
            }
            #expect(events.contains(.inputSubmitted(correctionID)))
            #expect(events.contains(.inputAcknowledged(correctionID)))
            #expect(events.contains(.assistantText("Corrected: test rows excluded.")))
            #expect(events.contains(.completed(resultText: "fixture complete")))
            #expect(FileManager.default.fileExists(atPath: fixture.marker.path))
            assertClean(events)
        }
    }

    @Test("Waiting for the user's decision does not consume the worker's wall budget, but the review allowance is bounded",
          arguments: [false, true])
    func reviewTimePausesWallClock(exceedReview: Bool) async throws {
        let ledger = ApprovalLedger()
        let limits = FirstToolJobLaunchLimits(maximumWallTimeSeconds: 2, startupTimeoutSeconds: 1.5,
                                              maximumReviewSeconds: exceedReview ? 1 : 30)
        try await withPeer(mode: "tool", role: .worker, limits: limits, ledger: ledger) { fixture, process in
            try await process.start(initialInput: "Create the fixture output")
            var events: [FirstToolJobProcessEvent] = []
            for await event in process.events {
                events.append(event)
                if case .toolRequested(let invocation) = event {
                    // Longer than the whole wall budget: only allowed because the clock is paused.
                    try await Task.sleep(for: .seconds(2.5))
                    let action = try fixture.action(invocation)
                    let receipt = try ledger.issue(receiptID: ApprovalReceiptID(UUID()), for: action,
                        issuedAt: fixture.now, expiresAt: fixture.now.addingTimeInterval(10))
                    do {
                        try await process.approve(requestID: invocation.requestID, action: action, receipt: receipt,
                            currentPolicyGeneration: 7, now: fixture.now)
                    } catch { #expect(exceedReview) }
                }
            }
            if exceedReview {
                #expect(events.contains(.failed(.wallTimeout)))
                #expect(!FileManager.default.fileExists(atPath: fixture.marker.path))
            } else {
                #expect(events.contains(.completed(resultText: "fixture complete")))
                #expect(FileManager.default.fileExists(atPath: fixture.marker.path))
            }
            assertClean(events)
        }
    }

    @Test("Cancellation cannot dispatch an allow response through the adapter")
    func cancelledApproval() async throws {
        let ledger = ApprovalLedger()
        try await withPeer(mode: "cancel", role: .worker, ledger: ledger) { fixture, process in
            try await process.start(initialInput: "Create the fixture output")
            var invocation: ProbeToolInvocation?
            var events: [FirstToolJobProcessEvent] = []
            for await event in process.events {
                events.append(event)
                if case .toolRequested(let value) = event { invocation = value }
                if case .approvalCancelled(let requestID) = event {
                    let request = try #require(invocation)
                    let action = try fixture.action(request)
                    let receipt = try ledger.issue(receiptID: ApprovalReceiptID(UUID()), for: action,
                        issuedAt: fixture.now, expiresAt: fixture.now.addingTimeInterval(10))
                    await #expect(throws: ProbeToolControlError.invalidApproval) {
                        try await process.approve(requestID: requestID, action: action, receipt: receipt,
                            currentPolicyGeneration: 7, now: fixture.now)
                    }
                }
            }
            #expect(!FileManager.default.fileExists(atPath: fixture.marker.path))
            #expect(!events.contains(.completed(resultText: "fixture complete")))
            assertClean(events)
        }
    }

    @Test("Rejected startup diagnostics contain fixed categories without provider payloads",
          arguments: ["status", "error", "foreign"])
    func rejectedStartupIsRedacted(_ kind: String) async throws {
        let expectedFrame: ProbeToolControlDiagnostic.Frame = switch kind {
        case "status": .systemStatus
        case "error": .controlError
        default: .controlSuccess
        }
        let expectedError: ProbeToolControlError = kind == "foreign" ? .wrongSession : .unexpectedFrame
        var descriptions: [String] = []
        for suffix in ["first", "second"] {
            let mode = "diagnostic-\(kind)-\(suffix)"
            try await withPeer(mode: mode, role: .worker) { fixture, process in
                try await process.start(initialInput: "Synthetic input must not be submitted")
                let events = await collected(process)
                let diagnostics = events.compactMap { event -> ProbeToolControlDiagnostic? in
                    if case .failed(.protocolRejected(let diagnostic)) = event { return diagnostic }; return nil
                }
                #expect(diagnostics.count == 1)
                let diagnostic = try #require(diagnostics.first)
                #expect(diagnostic.stage == .awaitingControl)
                #expect(diagnostic.frame == expectedFrame)
                #expect(diagnostic.error == expectedError)
                #expect(diagnostic.description.utf8.count <= 256)
                #expect(!diagnostic.description.contains("SYNTHETIC_PRIVATE_"))
                #expect(!diagnostic.description.contains("/private/fixture-only/"))
                #expect(!diagnostic.description.localizedCaseInsensitiveContains(fixture.plan.sessionID.uuidString))
                descriptions.append(diagnostic.description)
                #expect(!events.contains { event in
                    switch event {
                    case .initialized, .inputSubmitted, .inputAcknowledged, .assistantText, .toolRequested, .completed: true
                    default: false
                    }
                })
                #expect(!FileManager.default.fileExists(atPath: fixture.marker.path))
                assertClean(events)
            }
        }
        // Fresh session IDs, private payloads and request IDs must not change
        // the static diagnostic for the same rejected stage/frame/error.
        #expect(descriptions.count == 2)
        #expect(descriptions.first == descriptions.last)
    }

    @Test("Foreign, malformed, oversized and tool-bearing conversation frames terminate the owned group",
          arguments: ["foreign", "malformed", "oversized", "tool", "blank", "partial"])
    func badFrames(_ mode: String) async throws {
        try await withPeer(mode: mode, role: .conversation) { _, process in
            try await process.start(initialInput: "Synthetic input")
            let events = await collected(process)
            if mode == "oversized" { #expect(events.contains(.failed(.outputLimit))) }
            else if mode == "blank" || mode == "partial" { #expect(events.contains(.failed(.protocolViolation))) }
            else {
                let diagnostics = events.compactMap { event -> ProbeToolControlDiagnostic? in
                    if case .failed(.protocolRejected(let diagnostic)) = event { return diagnostic }; return nil
                }
                #expect(diagnostics.count == 1)
                let diagnostic = try #require(diagnostics.first)
                #expect(diagnostic.stage == .active)
                #expect(diagnostic.frame == (mode == "malformed" ? .invalidJSON : .assistant))
                let expectedError: ProbeToolControlError = switch mode {
                case "foreign": .wrongSession
                case "malformed": .malformed
                default: .unexpectedFrame
                }
                #expect(diagnostic.error == expectedError)
            }
            assertClean(events)
        }
    }

    @Test("Startup needs initialization as well as acknowledgement; whole-process deadline remains independent",
          arguments: ["startup-timeout", "ack-no-init", "wall-timeout"])
    func deadlines(_ mode: String) async throws {
        let limits = FirstToolJobLaunchLimits(maximumWallTimeSeconds: 1,
            startupTimeoutSeconds: mode == "wall-timeout" ? 0.8 : 0.1)
        try await withPeer(mode: mode, role: .conversation, limits: limits) { _, process in
            try await process.start(initialInput: "Synthetic input")
            let events = await collected(process)
            #expect(events.contains(.failed(mode == "wall-timeout" ? .wallTimeout : .startupTimeout)))
            assertClean(events)
        }
    }

    @Test("A startup failure keeps timings and a bounded, control-free tail of the peer's stderr for diagnostics")
    func startupFailureRetainsStandardErrorTail() async throws {
        let limits = FirstToolJobLaunchLimits(maximumWallTimeSeconds: 2, startupTimeoutSeconds: 0.8)
        try await withPeer(mode: "stderr-then-timeout", role: .worker, limits: limits) { _, process in
            try await process.start(initialInput: "Synthetic input")
            let events = await collected(process)
            #expect(events.contains(.failed(.startupTimeout)))
            let diagnostics = await process.diagnostics()
            #expect(diagnostics.launchedAfter != nil)
            #expect(diagnostics.initializedAfter == nil)
            #expect(diagnostics.launchErrorDescription == nil)
            #expect(diagnostics.standardErrorTail.contains("SYNTHETIC_STDERR launch detail one"))
            #expect(diagnostics.standardErrorTail.contains("launch detail two tail"))
            #expect(!diagnostics.standardErrorTail.contains("\u{1b}"))
            #expect(!diagnostics.standardErrorTail.contains("\u{0}"))
            #expect(!diagnostics.standardErrorTail.contains("\n"))
            #expect(diagnostics.summary.contains("launchedAfter="))
            #expect(diagnostics.summary.contains("initializedAfter=-"))
            #expect(diagnostics.summary.contains("cli-stderr(bounded)=SYNTHETIC_STDERR"))
            assertClean(events)
        }
    }

    @Test("A refused admission names the underlying error for diagnostics while the user label stays generic")
    func refusedAdmissionNamesTheError() async throws {
        struct SyntheticGate: Error, CustomStringConvertible { var description: String { "SyntheticGate.subscriptionRequired" } }
        let process = FirstToolJobProcess(policyGeneration: 1, ledger: ApprovalLedger()) { throw SyntheticGate() }
        try await process.start(initialInput: "Synthetic input")
        let events = await collected(process)
        #expect(events.contains(.failed(.admissionDenied)))
        let diagnostics = await process.diagnostics()
        #expect(diagnostics.launchErrorDescription == "SyntheticGate.subscriptionRequired")
        #expect(diagnostics.launchedAfter == nil)
        #expect(diagnostics.summary.contains("launchError=SyntheticGate.subscriptionRequired"))
        #expect(diagnostics.summary.contains("cli-stderr(bounded)=-"))
    }

    @Test("The stderr tail is bounded and keeps the end")
    func standardErrorTailIsBoundedAndKeepsTheEnd() {
        let noisy = Data((String(repeating: "x", count: 10_000) + "\r\n\t\u{1b}[0m FINAL\u{0}WORD\n").utf8)
        let line = FirstToolJobProcessDiagnostics.sanitizedLine(noisy)
        #expect(line.count <= FirstToolJobProcessDiagnostics.standardErrorTailBytes)
        #expect(line.hasSuffix("FINAL WORD"))
        #expect(!line.contains("\u{1b}") && !line.contains("\u{0}") && !line.contains("\n"))
        #expect(FirstToolJobProcessDiagnostics.sanitizedLine(Data()) == "")
        let summary = FirstToolJobProcessDiagnostics(launchedAfter: 1.25, initializedAfter: nil,
            launchErrorDescription: nil, standardErrorTail: line).summary
        #expect(summary.hasPrefix("launchedAfter=1.2s initializedAfter=-; cli-stderr(bounded)="))
        #expect(summary.count <= 120 + FirstToolJobProcessDiagnostics.summaryStandardErrorCharacters)
    }

    @Test("An extra request cannot cross the admitted request budget")
    func requestLimit() async throws {
        try await withPeer(mode: "wait", role: .conversation,
                           limits: FirstToolJobLaunchLimits(maximumRequests: 1, maximumWallTimeSeconds: 4, startupTimeoutSeconds: 2)) { _, process in
            try await process.start(initialInput: "Only admitted request")
            var events: [FirstToolJobProcessEvent] = []
            for await event in process.events {
                events.append(event)
                if case .inputAcknowledged = event {
                    await #expect(throws: FirstToolJobProcessFailure.requestLimit) {
                        try await process.sendInput(text: "Not admitted")
                    }
                }
            }
            #expect(events.contains(.failed(.requestLimit)))
            #expect(events.filter { if case .inputSubmitted = $0 { return true }; return false }.count == 1)
            assertClean(events)
        }
    }

    @Test("Stop joins concurrent writers and reports group cleanup before it returns")
    func stopActiveProcess() async throws {
        try await withPeer(mode: "backpressure", role: .conversation,
                           limits: FirstToolJobLaunchLimits(maximumRequests: 8, maximumWallTimeSeconds: 10,
                               startupTimeoutSeconds: 2, writeTimeoutSeconds: 5)) { _, process in
            try await process.start(initialInput: "Synthetic input")
            var events: [FirstToolJobProcessEvent] = []
            for await event in process.events {
                events.append(event)
                if event == .assistantText("READY") {
                    let sending = Task {
                        for _ in 0..<7 { try await process.sendInput(text: String(repeating: "x", count: 8_192)) }
                    }
                    try await Task.sleep(for: .milliseconds(100))
                    let started = ContinuousClock.now
                    let receipt = await process.stop()
                    #expect(ContinuousClock.now - started < .seconds(2))
                    #expect(receipt?.exited == true && receipt?.processGroupGone == true)
                    _ = await sending.result
                }
            }
            #expect(!events.contains(.completed(resultText: "fixture complete")))
            assertClean(events)
        }
    }

    private func collected(_ process: FirstToolJobProcess) async -> [FirstToolJobProcessEvent] {
        var events: [FirstToolJobProcessEvent] = []
        for await event in process.events { events.append(event) }
        return events
    }

    private func assertClean(_ events: [FirstToolJobProcessEvent]) {
        let receipts = events.compactMap { event -> ProbeToolSessionCleanup? in
            if case .stopped(let receipt) = event { return receipt }; return nil
        }
        #expect(receipts.count == 1)
        #expect(receipts.first?.exited == true && receipts.first?.processGroupGone == true)
        for event in events {
            if case .started(_, _, let group) = event { #expect(kill(-group, 0) == -1 && errno == ESRCH) }
        }
    }

    @Test("A granted web tool is allowed through the same ledger, names its tool, and needs no card",
          arguments: [AgenticWebCapability.search, .fetch])
    func grantedWebToolAllowed(_ capability: AgenticWebCapability) async throws {
        let ledger = ApprovalLedger()
        try await withPeer(mode: capability == .search ? "websearch" : "webfetch", role: .worker, ledger: ledger,
                           webCapabilities: [capability]) { fixture, process in
            try await process.start(initialInput: "Look up the fixture totals")
            var events: [FirstToolJobProcessEvent] = []
            for await event in process.events {
                events.append(event)
                if case .toolRequested(let invocation) = event {
                    #expect(invocation.toolName == capability.toolName)
                    #expect(!FileManager.default.fileExists(atPath: fixture.marker.path))
                    let action = try fixture.webAction(invocation)
                    #expect(BrokerPolicy.approvalRequirement(for: action) == .explicitReadCapability)
                    let receipt = try ledger.issue(receiptID: ApprovalReceiptID(UUID()), for: action,
                        issuedAt: fixture.now, expiresAt: fixture.now.addingTimeInterval(10))
                    try await process.approve(requestID: invocation.requestID, action: action, receipt: receipt,
                        currentPolicyGeneration: 7, now: fixture.now)
                }
            }
            #expect(events.contains { if case .toolRequested = $0 { return true }; return false })
            #expect(FileManager.default.fileExists(atPath: fixture.marker.path))
            #expect(events.contains(.toolResult("fixture-web", failed: false)))
            #expect(events.contains(.completed(resultText: "fixture complete")))
            assertClean(events)
        }
    }

    @Test("A web tool the plan did not launch is refused wherever it first appears",
          arguments: ["web-unexpected-tool", "websearch"])
    func ungrantedWebToolRefused(_ mode: String) async throws {
        try await withPeer(mode: mode, role: .worker) { fixture, process in
            try await process.start(initialInput: "Look up the fixture totals")
            let events = await collected(process)
            let diagnostics = events.compactMap { event -> ProbeToolControlDiagnostic? in
                if case .failed(.protocolRejected(let diagnostic)) = event { return diagnostic }; return nil
            }
            #expect(diagnostics.count == 1)
            let diagnostic = try #require(diagnostics.first)
            #expect(diagnostic.error == .unexpectedFrame)
            if mode == "web-unexpected-tool" {
                #expect(diagnostic.stage == .awaitingInitialization && diagnostic.frame == .systemInit)
                #expect(!events.contains(.initialized))
            } else {
                #expect(diagnostic.stage == .active && diagnostic.frame == .assistant)
            }
            #expect(!events.contains { if case .toolRequested = $0 { return true }; return false })
            #expect(!FileManager.default.fileExists(atPath: fixture.marker.path))
            assertClean(events)
        }
    }

    @Test("An init frame that names a plugin, or leaves the plugin list out, is refused before the job starts",
          arguments: ["init-agents-md", "init-no-plugins"])
    func pluginInitRefused(_ mode: String) async throws {
        // Claude Code 2.1.281 announces a built-in AGENTS.md plugin unless the
        // settings switch it off; a frame that stops naming plugins proves nothing.
        try await withPeer(mode: mode, role: .worker) { fixture, process in
            try await process.start(initialInput: "Look up the fixture totals")
            let events = await collected(process)
            let diagnostics = events.compactMap { event -> ProbeToolControlDiagnostic? in
                if case .failed(.protocolRejected(let diagnostic)) = event { return diagnostic }; return nil
            }
            let diagnostic = try #require(diagnostics.first)
            #expect(diagnostics.count == 1)
            #expect(diagnostic.error == .unexpectedFrame)
            #expect(diagnostic.stage == .awaitingInitialization && diagnostic.frame == .systemInit)
            #expect(!events.contains(.initialized))
            #expect(!FileManager.default.fileExists(atPath: fixture.marker.path))
            assertClean(events)
        }
    }

    @Test("A fetch of a private address and a callback that misnames its tool both close the connection",
          arguments: ["webfetch-private", "web-mismatched-callback"])
    func forbiddenWebInputs(_ mode: String) async throws {
        let capability: AgenticWebCapability = mode == "webfetch-private" ? .fetch : .search
        try await withPeer(mode: mode, role: .worker, webCapabilities: [capability]) { fixture, process in
            try await process.start(initialInput: "Read the fixture page")
            let events = await collected(process)
            let diagnostics = events.compactMap { event -> ProbeToolControlDiagnostic? in
                if case .failed(.protocolRejected(let diagnostic)) = event { return diagnostic }; return nil
            }
            #expect(diagnostics.count == 1)
            let diagnostic = try #require(diagnostics.first)
            #expect(diagnostic.stage == .active && diagnostic.frame == .controlRequest)
            #expect(diagnostic.error == (mode == "webfetch-private" ? .forbiddenInput : .unexpectedFrame))
            #expect(!diagnostic.description.contains("127.0.0.1"))
            #expect(!events.contains { if case .toolRequested = $0 { return true }; return false })
            #expect(!FileManager.default.fileExists(atPath: fixture.marker.path))
            assertClean(events)
        }
    }

    // Generous by default: the first peer of a run starts a cold python3. On the
    // macos-26 CI runner the suite's first case alone came back with no summary
    // under the old two-second start budget. Tests of the deadlines pass their own.
    private func withPeer(mode: String, role: FirstToolJobProcessRole,
                          limits: FirstToolJobLaunchLimits = .init(maximumWallTimeSeconds: 20, startupTimeoutSeconds: 10),
                          ledger: ApprovalLedger = ApprovalLedger(),
                          webCapabilities: Set<AgenticWebCapability> = [],
                          body: (ProcessPeerFixture, FirstToolJobProcess) async throws -> Void) async throws {
        let fixture = try ProcessPeerFixture(mode: mode, role: role, limits: limits, webCapabilities: webCapabilities)
        let plan = fixture.plan
        let process = FirstToolJobProcess(policyGeneration: 7, ledger: ledger, admission: { plan })
        do { try await body(fixture, process) }
        catch {
            let cleanup = await process.stop()
            if cleanup == nil || cleanup?.processGroupGone == true { fixture.remove() }
            throw error
        }
        let cleanup = await process.stop()
        if cleanup == nil || cleanup?.processGroupGone == true { fixture.remove() }
    }
}

private actor ProcessAdmissionCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

private actor ProcessAdmissionGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

/// The internal plan constructor binds only a synthetic Python peer. These
/// fictional metadata values never pass native/provider admission or persist.
private struct ProcessPeerFixture: Sendable {
    let root: URL
    let plan: FirstToolJobLaunchPlan
    let now = Date(timeIntervalSince1970: 1_000)
    var marker: URL { plan.paths.workingDirectory.appending(path: "fixture-output.txt") }

    init(mode: String, role: FirstToolJobProcessRole, limits: FirstToolJobLaunchLimits,
         webCapabilities: Set<AgenticWebCapability> = []) throws {
        root = URL(fileURLWithPath: "/private/tmp/OpenBotsProcessAdapter-\(UUID()).noindex")
        let paths = try AgenticProbePaths(root: root, configurationDirectory: root.appending(path: "Profile"),
            homeDirectory: root.appending(path: "Home"), claudeExecutable: URL(fileURLWithPath: "/usr/bin/python3"))
        try FileManager.default.createDirectory(at: paths.workingDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let script = root.appending(path: "fixture-peer.py")
        try Self.script.write(to: script, atomically: true, encoding: .utf8)
        let receipt = FirstToolJobAdmissionReceipt(installation: FirstToolJobInstallationIdentity(
            requestedPath: "/usr/bin/python3", resolvedPath: "/usr/bin/python3", versionFilename: "fixture",
            sha256: String(repeating: "a", count: 64), signature: .init(identifier: "fixture", teamIdentifier: "fixture"),
            fileIdentity: .init(device: 1, inode: 1, byteCount: 1_024)),
            profile: FirstToolJobProfileMetadata(applicationSupportPath: root.path, profilePath: root.path, markerPath: root.path,
                installationID: UUID(), rootID: UUID(), bundleIdentifier: "fixture", markerSchemaVersion: 1, role: "fixture"),
            checkedAt: Date(timeIntervalSince1970: 1_000))
        let sessionID = UUID()
        let tools = role == .worker ? ["Bash"] + AgenticWebCapability.toolNames(webCapabilities) : []
        plan = FirstToolJobLaunchPlan(admission: receipt, paths: paths, role: role,
            teammateID: TeammateID(UUID()), runID: RunID(UUID()), sessionID: sessionID, model: "fixture",
            arguments: [script.path, mode, role.rawValue, sessionID.uuidString.lowercased(), tools.joined(separator: ",")],
            environment: ["PATH": "/usr/bin:/bin", "LANG": "C", "PYTHONDONTWRITEBYTECODE": "1"],
            settingsJSON: Data(), settingsSHA256: "fixture", mcpJSON: Data(), mcpSHA256: "fixture", limits: limits,
            webCapabilities: webCapabilities)
    }
    func action(_ invocation: ProbeToolInvocation) throws -> FrozenAction {
        try BrokerPolicy.freeze(ActionProposal(actionID: ActionID(UUID()), teammateID: plan.teammateID, runID: plan.runID,
            operation: .exclusiveCreateNewArtifactDelivery,
            targets: [CanonicalTarget(kind: .filesystem, canonicalIdentifier: marker.path, location: .appOwned, scope: .exactItem)],
            payloadDigest: invocation.payloadDigest, traversal: .exactTargets))
    }
    /// The read-only shape the native driver freezes for a granted web tool.
    func webAction(_ invocation: ProbeToolInvocation) throws -> FrozenAction {
        let input = try JSONSerialization.jsonObject(with: invocation.inputJSON) as? [String: Any]
        let subject = (input?["query"] as? String) ?? (input?["url"] as? String) ?? "-"
        return try BrokerPolicy.freeze(ActionProposal(actionID: ActionID(UUID()), teammateID: plan.teammateID, runID: plan.runID,
            operation: .readOnlyExternalAccess,
            targets: [CanonicalTarget(kind: .externalResource, canonicalIdentifier: "\(invocation.toolName):\(subject)",
                location: .notApplicable, scope: .exactItem)],
            payloadDigest: invocation.payloadDigest, traversal: .exactTargets))
    }
    func remove() { try? FileManager.default.removeItem(at: root) }

    private static let script = #"""
    import json, sys, time, uuid
    mode, role, session, tools = sys.argv[1:]
    tools = tools.split(",") if tools else []
    with open("fixture-started", "x") as f:
        f.write("synthetic peer started")
    def emit(value):
        print(json.dumps(value), flush=True)
    def read():
        return json.loads(sys.stdin.readline())
    if mode == "startup-timeout":
        time.sleep(10)
        sys.exit(0)
    if mode == "stderr-then-timeout":
        print("SYNTHETIC_STDERR launch detail one\x1b[31m", file=sys.stderr, flush=True)
        print("SYNTHETIC_STDERR launch detail two\x00tail", file=sys.stderr, flush=True)
        time.sleep(10)
        sys.exit(0)
    initial = read()
    assert initial["request"]["subtype"] == "initialize"
    assert bool(initial["request"]["hooks"]) == (role == "worker")
    if mode.startswith("diagnostic-"):
        category = mode.split("-")[1]
        sentinel = "SYNTHETIC_PRIVATE_" + mode
        private_payload = {"token": sentinel, "path": "/private/fixture-only/" + sentinel,
                           "text": sentinel + " must never enter a diagnostic"}
        if category == "status":
            emit({"type":"system","subtype":"status","session_id":session,"message":private_payload})
        elif category == "error":
            emit({"type":"control_response","response":{"request_id":initial["request_id"],
                  "subtype":"error","error":sentinel,"private_payload":private_payload}})
        else:
            emit({"type":"control_response","session_id":"00000000-0000-0000-0000-000000000000",
                  "response":{"request_id":initial["request_id"],"subtype":"success","response":private_payload}})
        sys.stdin.read()
        sys.exit(0)
    emit({"type":"keep_alive"})
    emit({"type":"control_response","response":{"request_id":initial["request_id"],"subtype":"success","response":{}}})
    user = read()
    if mode == "ack-no-init":
        emit(user)
        time.sleep(10)
        sys.exit(0)
    for state in ("queued", "started"):
        emit({"type":"command_lifecycle","command_uuid":user["uuid"],"session_id":session,
              "uuid":str(uuid.uuid4()),"state":state})
    announced_tools = tools + (["WebSearch"] if mode == "web-unexpected-tool" else [])
    init_frame = {"type":"system","subtype":"init","session_id":session,"tools":announced_tools,"mcp_servers":[],"plugins":[],"permissionMode":"default","apiKeySource":"none"}
    if mode == "init-no-plugins":
        del init_frame["plugins"]
    elif mode == "init-agents-md":
        init_frame["plugins"] = [{"name":"agents-md","path":"builtin","source":"agents-md@builtin"}]
    emit(init_frame)
    emit(user)
    def assistant(content, sid=session):
        emit({"type":"assistant","session_id":sid,"message":{"role":"assistant","content":content}})
    if mode.startswith("provider-"):
        failure = {"type":"result","session_id":session,"is_error":True,
                   "account":{"email":"object@example.invalid","token":"RAW_ACCOUNT"},
                   "usage":{"description":"RAW_USAGE"}}
        print("RAW_STDERR must never become a displayed failure reason", file=sys.stderr, flush=True)
        if mode == "provider-errors":
            failure["errors"] = ["The selected model is unavailable.", "Try again later."]
            failure["result"] = "RAW_FALLBACK must not supersede explicit errors"
        elif mode in ("provider-result", "provider-empty-errors"):
            failure["result"] = "The request exceeded the provider limit."
            if mode == "provider-empty-errors":
                failure["errors"] = []
        elif mode == "provider-secrets":
            failure["errors"] = ["Subscription refused for person@example.invalid. URL=https://example.invalid/check?code=urlSecret#fragment Bearer bearerSecret API_KEY=keySecret token: tokenSecret password=pwdSecret"]
        elif mode == "provider-token-patterns":
            failure["result"] = "Provider refused sk-ant-shortKey, ghp_shortKey, xoxb-shortKey, AIzaSHORTKEY."
        elif mode == "provider-labelled-value":
            failure["result"] = "Provider refused anthropicApiKey: tinyValue"
        elif mode == "provider-long-identifier":
            failure["errors"] = ["Rate limit exceeded. " + "a" * 2048 + " Retry in ten minutes."]
        elif mode == "provider-display-bound":
            failure["errors"] = ["A safe explanation. " * 80]
        elif mode == "provider-malformed-errors":
            failure["errors"] = [{"error":"RAW_MALFORMED"}]
            failure["result"] = "RAW_FALLBACK must not hide malformed errors"
        elif mode == "provider-malformed-result":
            failure["result"] = {"error":"RAW_MALFORMED"}
        elif mode == "provider-many-errors":
            failure["errors"] = ["RAW_EXCESS"] * 9
        elif mode == "provider-oversized-errors":
            failure["errors"] = ["RAW_OVERSIZED " + "x" * 8192]
        elif mode == "provider-oversized-result":
            failure["result"] = "RAW_OVERSIZED " + "x" * 8192
        elif mode == "provider-controls":
            failure["errors"] = ["RAW_CONTROL\u001b[31m\u0000\u202e must not render"]
        elif mode == "provider-empty":
            failure["errors"] = [" ", "\n"]
            failure["result"] = ""
        emit(failure)
    elif mode == "foreign":
        assistant([{"type":"text","text":"foreign"}], "00000000-0000-0000-0000-000000000000")
    elif mode == "malformed":
        print("{broken}", flush=True)
    elif mode == "blank":
        print("", flush=True)
    elif mode == "partial":
        sys.stdout.write('{"type":')
        sys.stdout.flush()
        sys.exit(0)
    elif mode == "oversized":
        sys.stdout.write("x" * 65537)
        sys.stdout.flush()
    elif mode in ("wall-timeout", "wait", "backpressure"):
        assistant([{"type":"text","text":"READY"}])
    elif mode == "correction":
        # Turn one: an approved command, its result, then the CLI's per-input
        # result while the correction is already queued on stdin. Turn two:
        # the correction is replayed, answered, and the final result follows.
        tool_input = {"command":"printf fixture"}
        assistant([{"type":"tool_use","id":"fixture-tool","name":"Bash","input":tool_input}])
        emit({"type":"control_request","request_id":"fixture-request","request":{"subtype":"hook_callback","callback_id":"openbots-first-job-bash","tool_use_id":"fixture-tool","input":{"hook_event_name":"PreToolUse","session_id":session,"tool_name":"Bash","tool_use_id":"fixture-tool","tool_input":tool_input}}})
        decision = read()
        assert decision["response"]["response"]["hookSpecificOutput"]["permissionDecision"] == "allow"
        emit({"type":"user","session_id":session,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"fixture-tool","is_error":False}]}})
        correction = read()
        assert correction["type"] == "user" and correction["message"]["content"] == "Exclude rows marked test.", correction
        emit({"type":"result","session_id":session,"is_error":False,"result":"first turn done"})
        emit(correction)
        assistant([{"type":"text","text":"Corrected: test rows excluded."}])
        with open("fixture-output.txt", "x") as f:
            f.write("corrected fixture result")
        emit({"type":"result","session_id":session,"is_error":False,"result":"fixture complete"})
    elif mode in ("tool", "cancel", "pair"):
        tool_input = {"command":"printf fixture"}
        assistant([{"type":"tool_use","id":"fixture-tool","name":"Bash","input":tool_input}])
        emit({"type":"control_request","request_id":"fixture-request","request":{"subtype":"hook_callback","callback_id":"openbots-first-job-bash","tool_use_id":"fixture-tool","input":{"hook_event_name":"PreToolUse","session_id":session,"tool_name":"Bash","tool_use_id":"fixture-tool","tool_input":tool_input}}})
        if mode == "cancel":
            emit({"type":"control_cancel_request","request_id":"fixture-request"})
        decision = read()
        hook = decision["response"]["response"]["hookSpecificOutput"]
        allowed = hook["permissionDecision"] == "allow"
        if mode == "pair":
            # The real CLI evaluates its ask rule after the hook allowed: the same
            # tool use returns as a permission callback under a new request ID,
            # with thinking-token progress frames around it (observed live).
            assert allowed and decision["response"]["request_id"] == "fixture-request"
            emit({"type":"system","subtype":"thinking_tokens","session_id":session,"uuid":str(uuid.uuid4()),"estimated_tokens":42,"estimated_tokens_delta":42})
            emit({"type":"control_request","request_id":"fixture-request-2","request":{"subtype":"can_use_tool","tool_name":"Bash","tool_use_id":"fixture-tool","input":tool_input}})
            second = read()
            body = second["response"]["response"]
            assert second["response"]["request_id"] == "fixture-request-2", second
            assert body["behavior"] == "allow" and body["updatedInput"] == tool_input and "hookSpecificOutput" not in body, second
        if allowed:
            assert hook["updatedInput"] == tool_input
            with open("fixture-output.txt", "x") as f:
                f.write("approved fixture result")
        emit({"type":"user","session_id":session,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"fixture-tool","is_error":not allowed}]}})
        emit({"type":"result","session_id":session,"is_error":not allowed,"result":"fixture complete"})
    elif mode in ("websearch", "webfetch", "web-mismatched-callback"):
        # A web tool arrives like Bash: announced, then a callback. The fetch
        # takes the permission leg, the search the hook leg; "mismatched"
        # names one tool in the callback identity and another in the hook.
        if mode == "webfetch":
            tool_name, tool_input = "WebFetch", {"url":"https://example.com/page","prompt":"Summarize the page"}
        else:
            tool_name, tool_input = "WebSearch", {"query":"fixture totals"}
        assistant([{"type":"tool_use","id":"fixture-web","name":tool_name,"input":tool_input}])
        if mode == "webfetch":
            emit({"type":"control_request","request_id":"fixture-web-request","request":{"subtype":"can_use_tool","tool_name":tool_name,"tool_use_id":"fixture-web","input":tool_input}})
        else:
            hook_tool = "Bash" if mode == "web-mismatched-callback" else tool_name
            emit({"type":"control_request","request_id":"fixture-web-request","request":{"subtype":"hook_callback","callback_id":"openbots-first-job-websearch","tool_use_id":"fixture-web","input":{"hook_event_name":"PreToolUse","session_id":session,"tool_name":hook_tool,"tool_use_id":"fixture-web","tool_input":tool_input}}})
        decision = read()
        body = decision["response"]["response"]
        if mode == "webfetch":
            allowed = body["behavior"] == "allow"
            if allowed:
                assert body["updatedInput"] == tool_input
        else:
            allowed = body["hookSpecificOutput"]["permissionDecision"] == "allow"
        if allowed:
            with open("fixture-output.txt", "x") as f:
                f.write(tool_name + " allowed")
        emit({"type":"user","session_id":session,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"fixture-web","is_error":not allowed}]}})
        emit({"type":"result","session_id":session,"is_error":not allowed,"result":"fixture complete"})
    elif mode == "webfetch-private":
        # The gate itself is under test, so the private address arrives as the
        # permission callback without a prior announcement.
        tool_input = {"url":"http://127.0.0.1:8080/admin","prompt":"Read it"}
        emit({"type":"control_request","request_id":"fixture-web-request","request":{"subtype":"can_use_tool","tool_name":"WebFetch","tool_use_id":"fixture-web","input":tool_input}})
        decision = read()
        with open("fixture-output.txt", "x") as f:
            f.write("must never be reached")
    else:
        assistant([{"type":"thinking","thinking":"hidden reasoning","signature":"fixture"},{"type":"text","text":"Visible fixture reply: café"}])
        emit({"type":"result","session_id":session,"is_error":False,"result":"fixture complete"})
    if mode == "backpressure":
        time.sleep(10)
    else:
        sys.stdin.read()
    """#
}
