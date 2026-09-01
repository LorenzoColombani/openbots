import Foundation
import OpenBotsContent
import OpenBotsDomain
import OpenBotsRuntime
import OpenBotsSecurity
import Testing
@testable import OpenBotsServices

private struct TextConnectionPreparationFixture: ClaudeConnectionPreparing {
    let result: ClaudeConnectionPreparation
    func prepareConnection() async -> ClaudeConnectionPreparation { result }
}

private struct TextPolicyFixture: ClaudeTextPolicyInspecting {
    let result: ClaudeTextPolicyAdmission
    func inspect(profileURL: URL) -> ClaudeTextPolicyAdmission { result }
}

private actor TextPreparationStatusFixture: ClaudeStatusChecking {
    let result: ClaudeConnectionStatusResult
    var calls = 0
    init(_ result: ClaudeConnectionStatusResult) { self.result = result }
    func checkStatus(target: ClaudeConnectionTarget) async -> ClaudeConnectionStatusResult {
        calls += 1; return result
    }
}

private func textPreparationFixture(status: TextPreparationStatusFixture,
                                    policy: ClaudeTextPolicyAdmission = .admitted,
                                    ready: Bool = true,
                                    suppliedLayout: PreviewStorageLayout? = nil,
                                    applicationSupportRoot: @escaping @Sendable () async -> VerifiedOwnedRoot? = { nil }) throws -> NativeClaudeTextLaunchPreparer {
    let layout = suppliedLayout ?? PreviewStorageLayout(homeDirectory: URL(fileURLWithPath: "/fixture-home"),
        systemTemporaryDirectory: URL(fileURLWithPath: "/fixture-tmp"))
    let target = try ClaudeConnectionTarget(executableURL: URL(fileURLWithPath: "/fixture-claude"),
        expectedExecutableSHA256: String(repeating: "a", count: 64), profileURL: layout.claudeCLIProfileRoot,
        workingDirectoryURL: layout.claudeCLIProfileRoot, temporaryDirectoryURL: layout.claudeCLIProfileRoot,
        homeDirectoryURL: layout.homeDirectory)
    let connection: ClaudeConnectionPreparation = ready
        ? .ready(local: .init(installation: .verified, profile: .metadataVerified), target: target)
        : .refused(.init(outcome: .problem(.installationMissing)))
    return NativeClaudeTextLaunchPreparer(layout: layout, applicationSupportRoot: applicationSupportRoot,
        connection: TextConnectionPreparationFixture(result: connection),
        policy: TextPolicyFixture(result: policy), status: status)
}

@Test("Text preflight requires installation and policy admission before any status operation")
func textPreparationRejectsBeforeStatus() async throws {
    for (ready, policy) in [(false, ClaudeTextPolicyAdmission.admitted),
                            (true, .rejected(.managedFilePresent)),
                            (true, .rejected(.inspectionUnavailable))] {
        let status = TextPreparationStatusFixture(.eligible(.max))
        let preparer = try textPreparationFixture(status: status, policy: policy, ready: ready)
        #expect(await status.calls == 0)
        guard case .refused = await preparer.prepareTextLaunch(runID: UUID()) else {
            Issue.record("Unadmitted text preparation was allowed"); return
        }
        #expect(await status.calls == 0)
    }
}

@Test("Text preflight never creates runtime material or signs in after missing subscription proof")
func textPreparationRequiresFreshSubscription() async throws {
    for result in [ClaudeConnectionStatusResult.signedOut, .inconclusive, .cancelled] {
        let status = TextPreparationStatusFixture(result)
        let preparer = try textPreparationFixture(status: status)
        guard case .refused(.subscriptionNotVerified) = await preparer.prepareTextLaunch(runID: UUID()) else {
            Issue.record("Missing proof must refuse this send"); return
        }
        #expect(await status.calls == 1)
    }
}

@Test("Even a verified subscription cannot bypass the owned runtime root")
func textPreparationRequiresOwnedRoot() async throws {
    let status = TextPreparationStatusFixture(.eligible(.pro))
    let preparer = try textPreparationFixture(status: status)
    guard case .refused(.setupRequired) = await preparer.prepareTextLaunch(runID: UUID()) else {
        Issue.record("Missing owned root must refuse this send"); return
    }
    #expect(await status.calls == 1)
}

@Test("Pro cannot admit native-1M Opus or create any turn directory", arguments: ["claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8", "claude-opus-5"])
func textPreparationRefusesMaxModelsOnProBeforeRuntimeMaterial(model: String) async throws {
    let fixture = try TextPreparationOwnedRootFixture()
    defer { fixture.remove() }
    let status = TextPreparationStatusFixture(.eligible(.pro))
    let roots = TextPreparationRootCounter(root: fixture.root)
    let preparer = try textPreparationFixture(status: status, suppliedLayout: fixture.layout,
        applicationSupportRoot: { await roots.value() })
    guard case .refused(.modelUnavailable) = await preparer.prepareTextLaunch(runID: UUID(), model: model) else {
        Issue.record("Pro must not admit a model that requires usage credits"); return
    }
    #expect(await status.calls == 1)
    #expect(await roots.calls == 0)
    #expect(!FileManager.default.fileExists(atPath: fixture.turns.path))
}

@Test("Max admits ordinary subscription model choices using the existing single subscription check", arguments: ClaudeTextOnlyRequest.supportedModels.subtracting(["claude-fable-5"]).sorted())
func textPreparationAdmitsMaxModelsOnMax(model: String) async throws {
    let fixture = try TextPreparationOwnedRootFixture()
    defer { fixture.remove() }
    let status = TextPreparationStatusFixture(.eligible(.max))
    let roots = TextPreparationRootCounter(root: fixture.root)
    let preparer = try textPreparationFixture(status: status, suppliedLayout: fixture.layout,
        applicationSupportRoot: { await roots.value() })
    let runID = UUID()
    guard case let .ready(target) = await preparer.prepareTextLaunch(runID: runID, model: model) else {
        Issue.record("Freshly verified Max should admit the pinned choice"); return
    }
    #expect(await status.calls == 1)
    #expect(await roots.calls == 1)
    #expect(target.workingDirectoryURL == fixture.turns.appending(path: "\(runID.uuidString)/Work.noindex", directoryHint: .isDirectory))
    #expect(try FileManager.default.contentsOfDirectory(atPath: target.workingDirectoryURL.path).isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: target.temporaryDirectoryURL.path).isEmpty)
}

@Test("Pro still admits existing Sonnet and pinned Sonnet/Haiku/Opus4.5 choices", arguments: ["sonnet", "claude-sonnet-4-6", "claude-sonnet-4-5-20250929", "claude-sonnet-5", "claude-haiku-4-5-20251001", "claude-opus-4-5-20251101"])
func textPreparationAdmitsNonMeteredProChoices(model: String) async throws {
    let status = TextPreparationStatusFixture(.eligible(.pro))
    let preparer = try textPreparationFixture(status: status)
    // Passing tier admission reaches the intentionally missing owned root.
    guard case .refused(.setupRequired) = await preparer.prepareTextLaunch(runID: UUID(), model: model) else {
        Issue.record("The model gate should preserve subscription-covered choices"); return
    }
    #expect(await status.calls == 1)
}

@Test("Unknown, floating Opus/Fable, and extended-context choices cannot gain native preparation", arguments: ["opus", "fable", "opus[1m]", "sonnet[1m]", "claude-opus-5[1m]", "claude-fable-5[1m]", "future-model"])
func textPreparationRefusesUnreviewedModelsWithoutStatus(model: String) async throws {
    let status = TextPreparationStatusFixture(.eligible(.max))
    let preparer = try textPreparationFixture(status: status)
    guard case .refused(.modelUnavailable) = await preparer.prepareTextLaunch(runID: UUID(), model: model) else {
        Issue.record("An unreviewed model must not gain preparation authority"); return
    }
    #expect(await status.calls == 0)
}

@Test("Old preparation adapters cannot implicitly prove Max eligibility", arguments: ["claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8", "claude-opus-5", "claude-fable-5"])
func textPreparationCompatibilityDefaultRefusesMaxModels(model: String) async {
    let preparer = TextPreparationLegacyAdapter()
    guard case .refused(.modelUnavailable) = await preparer.prepareTextLaunch(runID: UUID(), model: model) else {
        Issue.record("Compatibility must not infer a subscription tier"); return
    }
    #expect(await preparer.calls == 0)
    _ = await preparer.prepareTextLaunch(runID: UUID(), model: "sonnet")
    #expect(await preparer.calls == 1)
}

@Test("Unsupported and credit-dependent complete selections stop before status or runtime material")
func textPreparationRefusesFullSelectionsBeforeStatus() async throws {
    let selections: [(ClaudeExecutionSelection, ClaudeTextTurnProblem)] = [
        (.init(model: "future-model", effort: "default", contextWindow: "default"), .modelUnavailable),
        (.init(model: "claude-sonnet-4-6", effort: "xhigh", contextWindow: "default"), .effortUnavailable),
        (.init(model: "claude-haiku-4-5-20251001", effort: "default", contextWindow: "long"), .contextWindowUnavailable),
        (.init(model: "claude-sonnet-4-6", effort: "low", contextWindow: "long"), .contextWindowUnavailable),
        (.init(model: "claude-fable-5", effort: "default", contextWindow: "default"), .modelUnavailable),
        (.init(model: "claude-fable-5", effort: "max", contextWindow: "standard"), .modelUnavailable)
    ]
    for (selection, problem) in selections {
        let fixture = try TextPreparationOwnedRootFixture()
        defer { fixture.remove() }
        let status = TextPreparationStatusFixture(.eligible(.max))
        let roots = TextPreparationRootCounter(root: fixture.root)
        let preparer = try textPreparationFixture(status: status, suppliedLayout: fixture.layout,
            applicationSupportRoot: { await roots.value() })
        let outcome = await preparer.prepareTextLaunch(runID: UUID(), selection: selection)
        guard case .refused(let actual) = outcome else { Issue.record("Unsafe selection was admitted"); continue }
        #expect(actual == problem)
        #expect(await status.calls == 0)
        #expect(await roots.calls == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.turns.path))
    }
}

@Test("Fable cannot bypass the billing exclusion through older native preparation overloads")
func textPreparationLegacyModelOverloadAlsoRefusesFable() async throws {
    let status = TextPreparationStatusFixture(.eligible(.max))
    let preparer = try textPreparationFixture(status: status)
    guard case .refused(.modelUnavailable) = await preparer.prepareTextLaunch(runID: UUID(), model: "claude-fable-5") else {
        Issue.record("The model-only overload bypassed the billing exclusion"); return
    }
    #expect(await status.calls == 0)
}

@Test("Native full-selection admission accepts compatible explicit selectors without rewriting them")
func textPreparationAdmitsCompleteSubscriptionSelection() async throws {
    for selection in [ClaudeExecutionSelection(model: "claude-sonnet-5", effort: "low", contextWindow: "standard"),
                      ClaudeExecutionSelection(model: "claude-opus-4-6", effort: "max", contextWindow: "long")] {
        let fixture = try TextPreparationOwnedRootFixture()
        defer { fixture.remove() }
        let status = TextPreparationStatusFixture(.eligible(.max))
        let roots = TextPreparationRootCounter(root: fixture.root)
        let preparer = try textPreparationFixture(status: status, suppliedLayout: fixture.layout,
            applicationSupportRoot: { await roots.value() })
        let original = selection
        guard case .ready = await preparer.prepareTextLaunch(runID: UUID(), selection: selection) else {
            Issue.record("Compatible complete selection did not reach runtime preparation"); continue
        }
        #expect(selection == original)
        #expect(await status.calls == 1)
        #expect(await roots.calls == 1)
    }
}

@Test("Compatibility adapters cannot silently discard explicit effort or context")
func textPreparationCompatibilityRefusesDroppedSelectors() async {
    let preparer = TextPreparationLegacyAdapter()
    let explicitEffort = ClaudeExecutionSelection(model: "sonnet", effort: "low", contextWindow: "default")
    let explicitContext = ClaudeExecutionSelection(model: "sonnet", effort: "default", contextWindow: "standard")
    guard case .refused(.effortUnavailable) = await preparer.prepareTextLaunch(runID: UUID(), selection: explicitEffort),
          case .refused(.contextWindowUnavailable) = await preparer.prepareTextLaunch(runID: UUID(), selection: explicitContext) else {
        Issue.record("Compatibility adapter discarded a requested selector"); return
    }
    #expect(await preparer.calls == 0)
    _ = await preparer.prepareTextLaunch(runID: UUID(), selection: .init(model: "sonnet", effort: "default", contextWindow: "default"))
    #expect(await preparer.calls == 1)
}

private actor TextPreparationLegacyAdapter: ClaudeTextLaunchPreparing {
    var calls = 0
    func prepareTextLaunch(runID: UUID) async -> ClaudeTextLaunchPreparation {
        calls += 1
        return .refused(.setupRequired)
    }
}

private actor TextPreparationRootCounter {
    let root: VerifiedOwnedRoot
    var calls = 0
    init(root: VerifiedOwnedRoot) { self.root = root }
    func value() -> VerifiedOwnedRoot? { calls += 1; return root }
}

private struct TextPreparationOwnedRootFixture {
    let directory: URL
    let layout: PreviewStorageLayout
    let root: VerifiedOwnedRoot
    var turns: URL { layout.runtimeRoot.appending(path: "Claude/TextTurns", directoryHint: .isDirectory) }

    init() throws {
        directory = URL(fileURLWithPath: "/private/tmp/OpenBotsTextPreparation-\(UUID().uuidString).noindex", isDirectory: true)
        layout = PreviewStorageLayout(homeDirectory: directory.appending(path: "Home", directoryHint: .isDirectory),
            systemTemporaryDirectory: directory.appending(path: "Temporary", directoryHint: .isDirectory))
        let descriptor = layout.applicationSupportRoot
        try FileManager.default.createDirectory(at: descriptor.url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let installationID = UUID(), rootID = UUID()
        let marker = OwnedRootMarker(installationID: installationID, rootID: rootID, kind: .applicationSupport)
        try JSONEncoder().encode(marker).write(to: descriptor.ownershipMarkerURL, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: descriptor.ownershipMarkerURL.path)
        root = try OwnedRootVerifier().verify(descriptor, expectedInstallationID: installationID, expectedRootID: rootID)
        for child in [layout.highChurnRoot, layout.runtimeRoot, layout.runtimeRoot.appending(path: "Claude", directoryHint: .isDirectory)] {
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        }
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}
