import Darwin
import Foundation
import Testing
import OpenBotsDomain
import OpenBotsRuntime
@testable import OpenBotsServices

@Suite("Retained runtime compatibility service")
struct ClaudeRuntimeCompatibilityServiceTests {
    @Test("Missing separate-profile readiness refuses before invoking the runner")
    func readiness() async throws {
        let fixture = try CompatibilityServiceFixture()
        defer { fixture.remove() }
        let runner = CompatibilityScriptedRunner()
        let service = fixture.service(runner)
        #expect(try await service.run(fixture.request(ready: false)) == .authenticationRequired)
        #expect(await runner.requests.isEmpty)
    }

    @Test("Production-profile targets and unsupported contracts cannot run")
    func targetBoundary() async throws {
        let fixture = try CompatibilityServiceFixture()
        defer { fixture.remove() }
        let runner = CompatibilityScriptedRunner()
        let production = try fixture.target(profileName: "CLIProfile")
        let request = ClaudeRuntimeCompatibilityRequest(candidate: fixture.candidate, candidateTarget: production,
            contract: fixture.contract, validationProfileReady: true)
        #expect(await fixture.service(runner).run(request) == .failed(.init(reason: .invalidTarget)))
        #expect(await runner.requests.isEmpty)
    }

    @Test("Physical private temporary paths run and clean up despite Foundation alias normalization")
    func physicalTemporaryPath() async throws {
        let fixture = try CompatibilityServiceFixture(parent: URL(fileURLWithPath: "/private/tmp"))
        defer { fixture.remove() }
        let runner = CompatibilityScriptedRunner()
        let result = try await fixture.service(runner).run(fixture.request())
        guard case .passed = result else { Issue.record("Physical path must pass the offline suite: \(result)"); return }
        #expect(await runner.requests.count == 6)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.work.path).isEmpty)
    }

    @Test("An intermediate symlink in the workspace path is still refused")
    func symlinkWorkspacePath() async throws {
        let fixture = try CompatibilityServiceFixture(parent: URL(fileURLWithPath: "/private/tmp"))
        defer { fixture.remove() }
        let alias = fixture.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.work)
        let child = fixture.work.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let original = try fixture.target()
        let target = try ClaudeConnectionTarget(executableURL: original.executableURL,
            expectedExecutableSHA256: original.expectedExecutableSHA256, profileURL: original.profileURL,
            workingDirectoryURL: alias.appendingPathComponent("child"),
            temporaryDirectoryURL: original.temporaryDirectoryURL, homeDirectoryURL: original.homeDirectoryURL)
        let request = ClaudeRuntimeCompatibilityRequest(candidate: fixture.candidate, candidateTarget: target,
            contract: fixture.contract, validationProfileReady: true)
        let runner = CompatibilityScriptedRunner()
        #expect(await fixture.service(runner).run(request) == .failed(.init(reason: .invalidTarget)))
        #expect(await runner.requests.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: child.path).isEmpty)
    }

    @Test("Missing Node fails with an actionable reason before any prompt, and a later install is found on retry")
    func nodeResolvedForEveryRun() async throws {
        let fixture = try CompatibilityServiceFixture()
        defer { fixture.remove() }
        let node = CompatibilityNodeResolution()
        let runner = CompatibilityScriptedRunner()
        let service = ClaudeRuntimeCompatibilityService(runner: runner,
            fixtureURL: ServicesResourceBundle.url(forResource: "claude-runtime-compatibility", withExtension: "js"),
            nodeResolver: { node.value }, caseLimit: .seconds(5), overallLimit: .seconds(20),
            cleanupLimit: .seconds(1), requiresNativeReceipt: false, diagnosticSink: { _ in })
        let request = try fixture.request()
        let missing = await service.run(request)
        #expect(missing == .failed(.init(reason: .nodeUnavailable)))
        if case .failed(let failure) = missing {
            #expect(failure.message == "Node.js is needed to test this Claude Code version. Install it from nodejs.org or with Homebrew, then retry the compatibility checks.")
        }
        #expect(await runner.requests.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.work.path).isEmpty)
        node.set(URL(fileURLWithPath: "/usr/bin/unused-node"))
        let installed = await service.run(request)
        guard case .passed = installed else { Issue.record("Node found on retry must run the suite: \(installed)"); return }
        #expect(await runner.requests.count == 6)
    }

    @Test("Only the full six-prompt suite produces a receipt bound to active source and contract")
    func completeSuite() async throws {
        let fixture = try CompatibilityServiceFixture()
        defer { fixture.remove() }
        let runner = CompatibilityScriptedRunner()
        let request = try fixture.request(active: true)
        let result = await fixture.service(runner).run(request)
        guard case .passed(let receipt) = result else { Issue.record("Expected complete offline suite: \(result)"); return }
        #expect(receipt.artifact == fixture.candidate)
        #expect(receipt.contract == fixture.contract)
        #expect(receipt.compatibilityProfilePath == request.candidateTarget.profileURL.path)
        #expect(receipt.sourceRuntimeSHA256 == fixture.active.sha256)
        #expect(receipt.passedCases == Set(ClaudeRuntimeCompatibilityCase.allCases))
        let requests = await runner.requests
        #expect(requests.count == 6)
        #expect(requests.map(\.model) == ["haiku", "sonnet", "haiku", "haiku", "haiku", "haiku"])
        #expect(requests[4].target.expectedExecutableSHA256 == fixture.active.sha256)
        #expect(requests[5].target.expectedExecutableSHA256 == fixture.candidate.sha256)
        #expect(requests[4].sessionID == requests[5].sessionID)
        #expect(requests[4].persistsSession && !requests[4].resumesSession)
        #expect(requests[5].persistsSession && requests[5].resumesSession)
        #expect(!requests[5].text.contains("OPENBOTS_MEMORY_"))
        #expect(requests.allSatisfy { $0.allowedTools.isEmpty && $0.workAccess == nil && $0.readAccess == nil
            && !$0.grantsHiring && !$0.grantsWorkers && !$0.grantsSelfSetup })
        #expect(requests.allSatisfy { $0.target.profileURL == request.candidateTarget.profileURL
            && $0.target.workingDirectoryURL != request.candidateTarget.workingDirectoryURL })
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.work.path).isEmpty)
        #expect(await runner.stoppedStall)
    }

    @Test("Bootstrap continuation stays candidate-only and has no active-source hash")
    func bootstrap() async throws {
        let fixture = try CompatibilityServiceFixture()
        defer { fixture.remove() }
        let runner = CompatibilityScriptedRunner()
        let result = try await fixture.service(runner).run(fixture.request())
        guard case .passed(let receipt) = result else { Issue.record("Expected offline bootstrap pass: \(result)"); return }
        #expect(receipt.sourceRuntimeSHA256 == nil)
        #expect(await runner.requests.allSatisfy { $0.target.expectedExecutableSHA256 == fixture.candidate.sha256 })
    }

    @Test("New numeric Haiku and Sonnet alias resolutions pass only with matching terminal identities",
          arguments: [false, true])
    func newerAliasIdentities(suffixedSonnet: Bool) async throws {
        let fixture = try CompatibilityServiceFixture()
        defer { fixture.remove() }
        let lines = CompatibilityDiagnosticLines()
        let runner = CompatibilityScriptedRunner(modelBehavior: suffixedSonnet ? .suffixedSonnet : .newerAliases)
        let result = try await fixture.service(runner, diagnosticSink: { lines.append($0) }).run(fixture.request())
        guard case .passed(let receipt) = result else { Issue.record("Expected confirmed same-family alias pass: \(result)"); return }
        #expect(receipt.contract.suiteRevision == ClaudeRuntimeContract.currentSuiteRevision)
        #expect(receipt.passedCases == Set(ClaudeRuntimeCompatibilityCase.allCases))
        let requests = await runner.requests
        #expect(requests.count == 6)
        #expect(requests[0].expectedResolvedModel == "claude-haiku-4-5-20251001")
        #expect(requests[1].expectedResolvedModel == "claude-sonnet-5")
        #expect(lines.values.allSatisfy { $0.contains("checkpoint=passed") })
        #expect(lines.values.contains { $0.contains("alias=haiku") && $0.contains("init_model=claude-haiku-5-5")
            && $0.contains("confirmed=claude-haiku-5-5") })
        #expect(lines.values.contains { $0.contains("alias=sonnet") && $0.contains("init_model=claude-sonnet-5-5")
            && $0.contains("confirmed=claude-sonnet-5-5") })
    }

    @Test("Alias checks reject other families, nonnumeric versions and changes to the frozen initialized model")
    func aliasIdentityRefusals() async throws {
        let behaviors: [CompatibilityScriptedRunner.ModelBehavior] = [
            .opus, .fable, .wrongSonnetFamily, .nonnumeric, .changedInitialization,
            .changedActual, .changedConfirmed, .bundledTerminal
        ]
        for behavior in behaviors {
            let fixture = try CompatibilityServiceFixture()
            defer { fixture.remove() }
            let runner = CompatibilityScriptedRunner(modelBehavior: behavior)
            let result = try await fixture.service(runner).run(fixture.request())
            let expectedCase: ClaudeRuntimeCompatibilityCase = behavior == .wrongSonnetFamily ? .sonnetReply : .haikuReply
            #expect(result == .failed(.init(failedCase: expectedCase, reason: .protocolEvidenceMissing)))
            #expect(await runner.requests.count == (behavior == .wrongSonnetFamily ? 2 : 1))
        }
    }

    @Test("New alias identities still require terminal confirmation and matching runtime version")
    func newerAliasMissingEvidence() async throws {
        for fault in [CompatibilityScriptedRunner.Fault.unconfirmedResult, .wrongVersion] {
            let fixture = try CompatibilityServiceFixture()
            defer { fixture.remove() }
            let runner = CompatibilityScriptedRunner(fault: fault, modelBehavior: .newerAliases)
            #expect(try await fixture.service(runner).run(fixture.request())
                == .failed(.init(failedCase: .haikuReply, reason: .protocolEvidenceMissing)))
            #expect(await runner.requests.count == 1)
        }
    }

    @Test("Alias validation cannot issue a receipt under an older suite contract")
    func rejectsOlderSuiteContract() async throws {
        let fixture = try CompatibilityServiceFixture()
        defer { fixture.remove() }
        let runner = CompatibilityScriptedRunner(modelBehavior: .newerAliases)
        let contract = ClaudeRuntimeContract(appBuild: fixture.contract.appBuild,
            compatibilityProfileID: fixture.contract.compatibilityProfileID,
            suiteRevision: ClaudeRuntimeContract.currentSuiteRevision - 1)
        let request = try ClaudeRuntimeCompatibilityRequest(candidate: fixture.candidate, candidateTarget: fixture.target(),
            contract: contract, validationProfileReady: true)
        #expect(await fixture.service(runner).run(request) == .failed(.init(reason: .invalidTarget)))
        #expect(await runner.requests.isEmpty)
    }

    @Test("Missing or incorrect evidence never produces a partial pass", arguments: [
        CompatibilityScriptedRunner.Fault.missingVersion, .wrongVersion, .missingReplay,
        .unconfirmedResult, .wrongReply, .malformed, .deniedExecuted, .missingPermission, .missingToolResult
    ])
    fileprivate func evidenceRefusal(_ fault: CompatibilityScriptedRunner.Fault) async throws {
        let fixture = try CompatibilityServiceFixture()
        defer { fixture.remove() }
        let runner = CompatibilityScriptedRunner(fault: fault)
        let result = try await fixture.service(runner).run(fixture.request())
        guard case .failed = result else { Issue.record("Expected evidence refusal for \(fault): \(result)"); return }
        #expect(await runner.requests.count <= 3)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.work.path).isEmpty)
    }

    @Test("A synthetic success cannot satisfy the production native-completion requirement")
    func requiresNativeReceipt() async throws {
        let fixture = try CompatibilityServiceFixture()
        defer { fixture.remove() }
        let runner = CompatibilityScriptedRunner()
        let result = try await fixture.service(runner, requiresNativeReceipt: true).run(fixture.request())
        #expect(result == .failed(.init(failedCase: .haikuReply, reason: .protocolEvidenceMissing)))
        #expect(await runner.requests.count == 1)
    }

    @Test("Diagnostics identify the exact failed checkpoint without changing its result")
    func diagnosticCheckpoints() async throws {
        let cases: [(CompatibilityScriptedRunner.Fault, String, Bool)] = [
            (.missingVersion, "lifecycleEvidence", false), (.unconfirmedResult, "terminalModel", false),
            (.wrongReply, "sentinel", false), (.none, "nativeReceipt", true),
            (.diagnosticFailure, "lifecycleEvidence", false)
        ]
        for (fault, checkpoint, nativeReceipt) in cases {
            let fixture = try CompatibilityServiceFixture()
            defer { fixture.remove() }
            let lines = CompatibilityDiagnosticLines()
            let runner = CompatibilityScriptedRunner(fault: fault)
            let result = try await fixture.service(runner, requiresNativeReceipt: nativeReceipt,
                diagnosticSink: { lines.append($0) }).run(fixture.request())
            guard case .failed(let failure) = result else { Issue.record("Expected unchanged refusal"); continue }
            #expect(failure.failedCase == .haikuReply)
            #expect(failure.message.hasPrefix("Haiku reply: "))
            #expect(lines.values.count == 1)
            let line = try #require(lines.values.first)
            #expect(line.contains("case=haikuReply checkpoint=\(checkpoint)"))
            #expect(line.contains("alias=haiku") && line.contains("catalog=claude-haiku-4-5-20251001"))
            if fault == .missingVersion { #expect(line.contains("version=0") && line.contains("seen_version=none")) }
            if fault == .unconfirmedResult { #expect(line.contains("confirmed=none")) }
            if fault == .diagnosticFailure { #expect(line.contains("outcome=providerFailed") && line.contains("diag=providerFailure")) }
        }
    }

    @Test("Bounded diagnostics exclude prompts, paths, auth-shaped data and unadmitted metadata")
    func diagnosticPrivacy() async throws {
        let fixture = try CompatibilityServiceFixture()
        defer { fixture.remove() }
        let lines = CompatibilityDiagnosticLines()
        let runner = CompatibilityScriptedRunner(fault: .unsafeMetadata)
        let result = try await fixture.service(runner, diagnosticSink: { lines.append($0) }).run(fixture.request())
        #expect(result == .failed(.init(failedCase: .haikuReply, reason: .protocolEvidenceMissing)))
        let request = try #require(await runner.requests.first)
        let line = try #require(lines.values.first)
        #expect(lines.values.count == 1 && line.utf8.count <= 580)
        #expect(line.contains("init_model=redacted") && line.contains("seen_version=redacted"))
        #expect(line.contains("result_model=redacted") && line.contains("confirmed=redacted"))
        for privateValue in [request.text, request.systemPrompt, request.target.profileURL.path,
                             request.target.executableURL.path, "sk-proj-private-auth", "private@example.invalid"] {
            #expect(!line.contains(privateValue))
        }
    }

    @Test("Each completed synthetic request logs one bounded metadata line")
    func successfulDiagnostics() async throws {
        let fixture = try CompatibilityServiceFixture()
        defer { fixture.remove() }
        let lines = CompatibilityDiagnosticLines()
        let runner = CompatibilityScriptedRunner()
        let result = try await fixture.service(runner, diagnosticSink: { lines.append($0) }).run(fixture.request())
        guard case .passed = result else { Issue.record("Expected offline suite completion"); return }
        #expect(lines.values.count == 6)
        #expect(lines.values.allSatisfy { $0.contains("checkpoint=passed") && $0.utf8.count <= 580
            && !$0.contains("OPENBOTS_") && !$0.contains(fixture.root.path) })
    }

    @Test("Authentication failure stays actionable and never advances the suite")
    func authentication() async throws {
        let fixture = try CompatibilityServiceFixture()
        defer { fixture.remove() }
        let runner = CompatibilityScriptedRunner(fault: .authentication)
        #expect(try await fixture.service(runner).run(fixture.request()) == .authenticationRequired)
        #expect(await runner.requests.count == 1)
    }

    @Test("A stuck run is cancelled by the finite case budget without retry")
    func timeout() async throws {
        let fixture = try CompatibilityServiceFixture()
        defer { fixture.remove() }
        let runner = CompatibilityScriptedRunner(fault: .hang)
        let result = try await fixture.service(runner, caseLimit: .milliseconds(80)).run(fixture.request())
        #expect(result == .failed(.init(failedCase: .haikuReply, reason: .timedOut)))
        #expect(await runner.requests.count == 1)
        #expect(await runner.stoppedStall)
    }

    @Test("The overall deadline is shared across cases")
    func overallDeadline() async throws {
        let fixture = try CompatibilityServiceFixture()
        defer { fixture.remove() }
        let runner = CompatibilityScriptedRunner(fault: .delay)
        let result = try await fixture.service(runner, overallLimit: .milliseconds(150)).run(fixture.request())
        #expect(result == .failed(.init(failedCase: .sonnetReply, reason: .timedOut)))
        #expect(await runner.requests.count == 2)
    }

    @Test("Shutdown cancels and awaits the sole operation; concurrent checks are refused")
    func shutdown() async throws {
        let fixture = try CompatibilityServiceFixture()
        defer { fixture.remove() }
        let runner = CompatibilityScriptedRunner(fault: .hang)
        let service = fixture.service(runner)
        let task = Task { await service.run(try fixture.request()) }
        for _ in 0..<100 {
            if await !runner.requests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await service.run(fixture.request()) == .failed(.init(reason: .alreadyRunning)))
        await service.cancelAndWait()
        #expect(try await task.value == .cancelled)
        #expect(await runner.stoppedStall)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.work.path).isEmpty)
    }
}

private struct CompatibilityServiceFixture: Sendable {
    let root: URL
    let work: URL
    let contract = ClaudeRuntimeContract(appBuild: "offline-unit-test", compatibilityProfileID: UUID())
    let candidate = ClaudeRuntimeArtifact(version: "2.1.999", sha256: String(repeating: "a", count: 64),
        signatureIdentifier: "com.anthropic.claude-code", teamIdentifier: "Q6L2SF6YDW", codeDirectoryHash: String(repeating: "c", count: 40))
    let active = ClaudeRuntimeArtifact(version: "2.1.998", sha256: String(repeating: "b", count: 64),
        signatureIdentifier: "com.anthropic.claude-code", teamIdentifier: "Q6L2SF6YDW", codeDirectoryHash: String(repeating: "d", count: 40))
    init(parent: URL? = nil) throws {
        root = (parent ?? URL(fileURLWithPath: "/private/tmp"))
            .appendingPathComponent("compatibility-test-\(UUID()).noindex")
        work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for name in ["work", "temporary", "CompatibilityProfile", "CLIProfile"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        }
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func target(profileName: String = "CompatibilityProfile", active: Bool = false) throws -> ClaudeConnectionTarget {
        try ClaudeConnectionTarget(executableURL: root.appendingPathComponent(active ? "active-claude" : "candidate-claude"),
            expectedExecutableSHA256: active ? self.active.sha256 : candidate.sha256,
            profileURL: root.appendingPathComponent(profileName), workingDirectoryURL: work,
            temporaryDirectoryURL: root.appendingPathComponent("temporary"), homeDirectoryURL: root)
    }
    func request(ready: Bool = true, active: Bool = false) throws -> ClaudeRuntimeCompatibilityRequest {
        try ClaudeRuntimeCompatibilityRequest(candidate: candidate, candidateTarget: target(),
            active: active ? .init(artifact: self.active, target: target(active: true)) : nil,
            contract: contract, validationProfileReady: ready)
    }
    func service(_ runner: CompatibilityScriptedRunner, caseLimit: Duration = .seconds(5),
                 overallLimit: Duration = .seconds(20),
                 requiresNativeReceipt: Bool = false,
                 diagnosticSink: @escaping @Sendable (String) -> Void = { _ in }) -> ClaudeRuntimeCompatibilityService {
        ClaudeRuntimeCompatibilityService(runner: runner,
            fixtureURL: ServicesResourceBundle.url(forResource: "claude-runtime-compatibility", withExtension: "js"),
            nodeURL: URL(fileURLWithPath: "/usr/bin/unused-node"), caseLimit: caseLimit,
            overallLimit: overallLimit, cleanupLimit: .seconds(1), requiresNativeReceipt: requiresNativeReceipt,
            diagnosticSink: diagnosticSink)
    }
}

private actor CompatibilityScriptedRunner: ClaudeTextOnlyRunning {
    enum Fault: Sendable, Equatable { case none, missingVersion, wrongVersion, missingReplay, unconfirmedResult, wrongReply,
        malformed, deniedExecuted, missingPermission, missingToolResult, authentication, hang, delay,
        unsafeMetadata, diagnosticFailure }
    enum ModelBehavior: Sendable, Equatable {
        case bundled, newerAliases, suffixedSonnet, opus, fable, wrongSonnetFamily,
             nonnumeric, changedInitialization, changedActual, changedConfirmed, bundledTerminal
    }
    let fault: Fault
    let modelBehavior: ModelBehavior
    private(set) var requests: [ClaudeTextOnlyRequest] = []
    private(set) var stoppedStall = false
    private var token: String?
    init(fault: Fault = .none, modelBehavior: ModelBehavior = .bundled) {
        self.fault = fault; self.modelBehavior = modelBehavior
    }
    func run(request: ClaudeTextOnlyRequest,
             onEvent: @escaping @Sendable (ClaudeTextOnlyEvent) async -> Void) async -> ClaudeTextOnlyResult {
        await run(request: request, control: nil, onEvent: onEvent)
    }
    func run(request: ClaudeTextOnlyRequest, control: ClaudeTextTurnControl?,
             onEvent: @escaping @Sendable (ClaudeTextOnlyEvent) async -> Void) async -> ClaudeTextOnlyResult {
        requests.append(request)
        if fault == .authentication { return .failed(.authenticationRequired) }
        if fault == .malformed { return .failed(.invalidStream) }
        if fault == .diagnosticFailure {
            await onEvent(.diagnostic(.providerFailure))
            return .failed(.providerFailed)
        }
        if fault == .unsafeMetadata {
            await onEvent(.initialized(sessionID: request.sessionID, actualModel: "private@example.invalid"))
            await onEvent(.runtimeVersion(request.target.profileURL.path))
            return .success(.init(sessionID: request.sessionID, actualModel: "sk-proj-private-auth",
                text: request.text + request.systemPrompt, confirmedActualModel: request.target.executableURL.path))
        }
        if fault == .hang { return await stall() }
        if fault == .delay {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return .cancelled }
        }
        let newerIdentity = "claude-" + request.model + "-5-5"
        let initializedModel: String
        switch modelBehavior {
        case .bundled: initializedModel = request.expectedResolvedModel
        case .opus: initializedModel = "claude-opus-5-5"
        case .fable: initializedModel = "claude-fable-5-1"
        case .wrongSonnetFamily: initializedModel = "claude-haiku-5-5"
        case .nonnumeric: initializedModel = "claude-" + request.model + "-preview-5"
        case .suffixedSonnet: initializedModel = newerIdentity + (request.model == "sonnet" ? "[1m]" : "")
        default: initializedModel = newerIdentity
        }
        await onEvent(.inputSubmitted(messageID: request.messageID))
        await onEvent(.initialized(sessionID: request.sessionID, actualModel: initializedModel))
        if modelBehavior == .changedInitialization {
            await onEvent(.initialized(sessionID: request.sessionID, actualModel: "claude-" + request.model + "-5-6"))
        }
        if fault != .missingReplay { await onEvent(.inputAcknowledged(messageID: request.messageID)) }
        if fault != .missingVersion {
            await onEvent(.runtimeVersion(fault == .wrongVersion ? "wrong" : request.target.expectedExecutableSHA256.hasPrefix("b") ? "2.1.998" : "2.1.999"))
        }
        var reply: String
        if let server = request.connectorAccess?.servers.first {
            await onEvent(.controlReady)
            let isStall = request.text.contains("__stall")
            let names = isStall ? ["stall"] : ["allow", "deny"]
            for name in names {
                let qualified = "mcp__openbots_compatibility__" + name
                await onEvent(.toolUse(.init(id: name, toolName: qualified, inputJSON: Data("{}".utf8))))
                if fault != .missingPermission {
                    let permission = ClaudeTextPermissionRequest(requestID: name, toolUseID: name,
                        toolName: qualified, inputJSON: Data("{}".utf8))
                    control?.register(permission)
                    await onEvent(.permissionRequested(permission))
                    _ = control?.takePending()
                }
                if !isStall && fault != .missingToolResult { await onEvent(.toolFinished(toolUseID: name, failed: name == "deny")) }
            }
            if case .node(_, let entry) = server.program {
                do { try ledger(at: entry.deletingLastPathComponent(), events: isStall ? ["executed_stall"]
                    : fault == .deniedExecuted ? ["executed_allow", "executed_deny"] : ["executed_allow"]) }
                catch { return .failed(.processFailed) }
            }
            if isStall { return await stall() }
            reply = "OPENBOTS_TOOLS_OK"
        } else if request.resumesSession {
            reply = token ?? "missing"
        } else if request.persistsSession {
            token = request.text.components(separatedBy: "next turn: ").last?.components(separatedBy: ".").first
            reply = "OPENBOTS_REMEMBERED"
        } else { reply = request.model == "sonnet" ? "OPENBOTS_SONNET_OK" : "OPENBOTS_HAIKU_OK" }
        let actualModel = modelBehavior == .changedActual ? "claude-" + request.model + "-5-6"
            : modelBehavior == .bundledTerminal ? request.expectedResolvedModel
            : modelBehavior == .suffixedSonnet ? newerIdentity : initializedModel
        let confirmedModel = modelBehavior == .changedConfirmed ? "claude-" + request.model + "-5-6" : actualModel
        return .success(.init(sessionID: request.sessionID, actualModel: actualModel,
            text: fault == .wrongReply ? "wrong" : reply,
            confirmedActualModel: fault == .unconfirmedResult ? nil : confirmedModel))
    }
    private func stall() async -> ClaudeTextOnlyResult {
        while !Task.isCancelled {
            do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
        }
        stoppedStall = true
        return .cancelled
    }
    private func ledger(at directory: URL, events: [String]) throws {
        // Intentionally impossible fixture PIDs, only in this injected offline runner.
        let values = (["started", "initialized", "listed"] + events).map {
            ["event": $0, "pid": Int32.max - 1, "parentPID": Int32.max - 2] as [String: Any]
        }
        let data = try values.reduce(into: Data()) { $0 += try JSONSerialization.data(withJSONObject: $1); $0.append(10) }
        let file = directory.appendingPathComponent("ledger-\(Int32.max - 1).jsonl")
        try data.write(to: file, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

private final class CompatibilityNodeResolution: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?
    func set(_ value: URL?) { lock.withLock { url = value } }
    var value: URL? { lock.withLock { url } }
}

private final class CompatibilityDiagnosticLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var values: [String] { lock.withLock { lines } }
}
