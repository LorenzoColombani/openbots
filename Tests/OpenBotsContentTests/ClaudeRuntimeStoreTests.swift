import CryptoKit
import Darwin
import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsContent

private struct RuntimeStoreFixture: @unchecked Sendable {
    let container: ContentTemporaryFixture
    let root: VerifiedOwnedRoot
    let contract: ClaudeRuntimeContract
    var layout: PreviewStorageLayout { container.layout }
    var store: ClaudeRuntimeStore { ClaudeRuntimeStore(applicationSupportRoot: root, layout: layout) }

    init() throws {
        container = try ContentTemporaryFixture()
        let installationID = UUID(); let rootID = UUID()
        try container.materializeOwnedRoot(container.layout.applicationSupportRoot,
                                          installationID: installationID, rootID: rootID)
        root = try OwnedRootVerifier().verify(container.layout.applicationSupportRoot,
            expectedInstallationID: installationID, expectedRootID: rootID)
        for url in [container.layout.highChurnRoot, container.layout.runtimeRoot,
                    container.layout.claudeCLIProfileRoot.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let compatibility = container.layout.withClaudeProfilePurpose(.compatibility)
        try ClaudeProfileProvisioner().ensureExists(applicationSupportRoot: root, layout: compatibility)
        contract = try ClaudeRuntimeContract(appBuild: "fixture-build", compatibilityProfileID:
            ClaudeProfileInspector().verifiedProfileIdentity(applicationSupportRoot: root, layout: compatibility))
    }

    func source(_ version: String) throws -> (URL, ClaudeRuntimeArtifact) {
        let data = Data([0xcf, 0xfa, 0xed, 0xfe]) + Data(version.utf8)
        let url = container.home.appending(path: "source-\(version)")
        try data.write(to: url); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return (url, ClaudeRuntimeArtifact(version: version,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            signatureIdentifier: "com.anthropic.claude-code", teamIdentifier: "Q6L2SF6YDW",
            codeDirectoryHash: String(repeating: "a", count: 40)))
    }

    func receipt(_ artifact: ClaudeRuntimeArtifact, source: String? = nil,
                 cases: Set<ClaudeRuntimeCompatibilityCase> = Set(ClaudeRuntimeCompatibilityCase.allCases)) -> ClaudeRuntimeCompatibilityReceipt {
        ClaudeRuntimeCompatibilityReceipt(artifact: artifact, contract: contract,
            compatibilityProfilePath: layout.withClaudeProfilePurpose(.compatibility).claudeCLIProfileRoot.path,
            sourceRuntimeSHA256: source, passedCases: cases, completedAt: Date())
    }
}

@Test("Retained copy survives removal of global source and preserves active and previous atomically")
func retainedRuntimeSelectionSurvivesGlobalDeletion() async throws {
    let fixture = try RuntimeStoreFixture(); let store = fixture.store
    let (sourceA, a) = try fixture.source("A")
    let first = try await store.importCandidate(sourceURL: sourceA, artifact: a, expectedGeneration: 0)
    #expect(first.active == nil)
    try FileManager.default.removeItem(at: sourceA)
    let active = try await store.promote(receipt: fixture.receipt(a), contract: fixture.contract,
                                         expectedGeneration: first.generation)
    let (sourceB, b) = try fixture.source("B")
    let staged = try await store.importCandidate(sourceURL: sourceB, artifact: b, expectedGeneration: active.generation)
    #expect(staged.active == a)
    let switched = try await store.promote(receipt: fixture.receipt(b, source: a.sha256), contract: fixture.contract,
                                           expectedGeneration: staged.generation)
    let restored = try await fixture.store.load()
    #expect(restored == switched)
    #expect(restored.active == b && restored.previous == a && restored.candidate == nil)
    for url in [fixture.layout.claudeRetainedExecutableURL(sha256: a.sha256),
                fixture.layout.claudeRetainedExecutableURL(sha256: b.sha256)] {
        var metadata = stat(); #expect(lstat(url.path, &metadata) == 0)
        #expect(metadata.st_mode & 0o7777 == 0o700 && metadata.st_nlink == 1)
    }
    var metadata = stat(); #expect(lstat(fixture.layout.claudeRuntimeStateURL.path, &metadata) == 0)
    #expect(metadata.st_mode & 0o7777 == 0o600 && metadata.st_nlink == 1)
}

@Test("Partial, stale generation and replaced-profile receipts cannot activate a candidate")
func retainedRuntimeRejectsStaleAndIncompleteReceipts() async throws {
    let fixture = try RuntimeStoreFixture(); let store = fixture.store
    let (source, artifact) = try fixture.source("A")
    let staged = try await store.importCandidate(sourceURL: source, artifact: artifact, expectedGeneration: 0)
    await #expect(throws: ClaudeRuntimeStoreError.staleGeneration) {
        try await store.promote(receipt: fixture.receipt(artifact), contract: fixture.contract, expectedGeneration: 0)
    }
    await #expect(throws: ClaudeRuntimeStoreError.invalidReceipt) {
        try await store.promote(receipt: fixture.receipt(artifact, cases: [.haikuReply]),
                                contract: fixture.contract, expectedGeneration: staged.generation)
    }
    for revision in [1, ClaudeRuntimeContract.currentSuiteRevision + 1] {
        let contract = ClaudeRuntimeContract(appBuild: fixture.contract.appBuild,
            compatibilityProfileID: fixture.contract.compatibilityProfileID, suiteRevision: revision)
        let receipt = ClaudeRuntimeCompatibilityReceipt(artifact: artifact, contract: contract,
            compatibilityProfilePath: fixture.layout.withClaudeProfilePurpose(.compatibility).claudeCLIProfileRoot.path,
            sourceRuntimeSHA256: nil, passedCases: Set(ClaudeRuntimeCompatibilityCase.allCases), completedAt: Date())
        await #expect(throws: ClaudeRuntimeStoreError.invalidReceipt) {
            try await store.promote(receipt: receipt, contract: contract, expectedGeneration: staged.generation)
        }
    }
    let validation = fixture.layout.withClaudeProfilePurpose(.compatibility)
    try FileManager.default.removeItem(at: validation.claudeCLIProfileRoot)
    try ClaudeProfileProvisioner().ensureExists(applicationSupportRoot: fixture.root, layout: validation)
    await #expect(throws: ClaudeRuntimeStoreError.invalidReceipt) {
        try await store.promote(receipt: fixture.receipt(artifact), contract: fixture.contract,
                                expectedGeneration: staged.generation)
    }
    #expect(try await store.load() == staged)
}

@Test("Hard linked or substituted source bytes never become candidates")
func retainedRuntimeRefusesLinkedOrWrongSource() async throws {
    let fixture = try RuntimeStoreFixture(); let store = fixture.store
    let (source, artifact) = try fixture.source("A")
    let link = source.appendingPathExtension("link")
    try FileManager.default.linkItem(at: source, to: link)
    await #expect(throws: ClaudeRuntimeStoreError.unsafeEntry) {
        try await store.importCandidate(sourceURL: source, artifact: artifact, expectedGeneration: 0)
    }
    try FileManager.default.removeItem(at: link)
    try Data("changed".utf8).write(to: source)
    await #expect(throws: ClaudeRuntimeStoreError.invalidArtifact) {
        try await store.importCandidate(sourceURL: source, artifact: artifact, expectedGeneration: 0)
    }
    #expect(try await store.load() == ClaudeRuntimeState())
}

@Test("Source mutation during descriptor copy never publishes the copied candidate")
func retainedRuntimeRejectsSourceChangeDuringCopy() async throws {
    let fixture = try RuntimeStoreFixture(); let (source, artifact) = try fixture.source("A")
    let store = ClaudeRuntimeStore(applicationSupportRoot: fixture.root, layout: fixture.layout,
        beforePublication: nil, afterSourceCopy: { try Data("changed during copy".utf8).write(to: source) })
    await #expect(throws: ClaudeRuntimeStoreError.changedIdentity) {
        try await store.importCandidate(sourceURL: source, artifact: artifact, expectedGeneration: 0)
    }
    #expect(try await fixture.store.load() == ClaudeRuntimeState())
    #expect(!FileManager.default.fileExists(atPath: fixture.layout.claudeRetainedExecutableURL(sha256: artifact.sha256).path))
}

@Test("Tampered retained bytes block promotion and leave selection unchanged")
func retainedRuntimeRejectsTamperingAtPromotion() async throws {
    let fixture = try RuntimeStoreFixture(); let store = fixture.store
    let (source, artifact) = try fixture.source("A")
    let staged = try await store.importCandidate(sourceURL: source, artifact: artifact, expectedGeneration: 0)
    try Data("changed".utf8).write(to: fixture.layout.claudeRetainedExecutableURL(sha256: artifact.sha256))
    await #expect(throws: ClaudeRuntimeStoreError.invalidArtifact) {
        try await store.promote(receipt: fixture.receipt(artifact), contract: fixture.contract,
                                expectedGeneration: staged.generation)
    }
    #expect(try await store.load() == staged)
}

@Test("Publication failure keeps the old complete state and explicit retry clears only the attempt")
func retainedRuntimePublicationFailureAndExplicitRetry() async throws {
    let fixture = try RuntimeStoreFixture(); let (source, artifact) = try fixture.source("A")
    let store = fixture.store
    let staged = try await store.importCandidate(sourceURL: source, artifact: artifact, expectedGeneration: 0)
    let failing = ClaudeRuntimeStore(applicationSupportRoot: fixture.root, layout: fixture.layout,
                                    beforePublication: { throw ClaudeRuntimeStoreError.unavailable })
    await #expect(throws: ClaudeRuntimeStoreError.unavailable) {
        try await failing.recordResult(ClaudeRuntimeCheckResult(artifactSHA256: artifact.sha256,
            contract: fixture.contract, status: .running), expectedGeneration: staged.generation)
    }
    #expect(try await store.load() == staged)
    let failed = try await store.recordResult(ClaudeRuntimeCheckResult(artifactSHA256: artifact.sha256,
        contract: fixture.contract, status: .failed, message: "fixture failure"), expectedGeneration: staged.generation)
    let retry = try await store.explicitRetry(expectedGeneration: failed.generation, contract: fixture.contract)
    #expect(retry.lastResult == nil && retry.candidate == artifact && retry.active == nil)
    #expect(retry.generation == failed.generation + 1)
}

@Test("Owned ancestor replacement immediately before state publication is refused")
func retainedRuntimePublicationRejectsAncestorSwap() async throws {
    let fixture = try RuntimeStoreFixture(); let (source, artifact) = try fixture.source("A")
    let runtime = fixture.layout.runtimeRoot
    let store = ClaudeRuntimeStore(applicationSupportRoot: fixture.root, layout: fixture.layout,
        beforePublication: {
            try FileManager.default.moveItem(at: runtime, to: runtime.appendingPathExtension("previous"))
            try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        })
    await #expect(throws: ClaudeRuntimeStoreError.changedIdentity) {
        try await store.importCandidate(sourceURL: source, artifact: artifact, expectedGeneration: 0)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: runtime.path).isEmpty)
}

@Test("Per-identity failed checks survive candidate changes and restart without evicting earlier attempts")
func retainedRuntimeCheckHistoryIsDurableAndHasNoAttemptCountCliff() async throws {
    let fixture = try RuntimeStoreFixture(); let store = fixture.store
    let (sourceA, a) = try fixture.source("A")
    var state = try await store.importCandidate(sourceURL: sourceA, artifact: a, expectedGeneration: 0)
    for index in 0..<35 {
        let contract = ClaudeRuntimeContract(appBuild: "build-\(index)",
                                             compatibilityProfileID: fixture.contract.compatibilityProfileID)
        state = try await store.recordResult(ClaudeRuntimeCheckResult(artifactSHA256: a.sha256,
            contract: contract, status: .failed, message: "bounded fixture failure"), expectedGeneration: state.generation)
    }
    let (sourceB, b) = try fixture.source("B")
    state = try await store.importCandidate(sourceURL: sourceB, artifact: b, expectedGeneration: state.generation)
    let firstContract = ClaudeRuntimeContract(appBuild: "build-0",
                                              compatibilityProfileID: fixture.contract.compatibilityProfileID)
    let earlier = try await fixture.store.checkResult(artifactSHA256: a.sha256, contract: firstContract)
    #expect(earlier?.status == .failed)
    #expect(state.candidate == b && state.lastResult == nil)
    #expect(try await store.checkResult(artifactSHA256: b.sha256, contract: firstContract) == nil)
}

@Test("A selected runtime without its exact full passing receipt fails closed on restart")
func retainedRuntimeRequiresBoundActiveReceiptOnLoad() async throws {
    for mutation in ["missing", "partial", "mismatched", "unknownSuite"] {
        let fixture = try RuntimeStoreFixture(); let store = fixture.store
        let (source, artifact) = try fixture.source("A")
        let staged = try await store.importCandidate(sourceURL: source, artifact: artifact, expectedGeneration: 0)
        let active = try await store.promote(receipt: fixture.receipt(artifact), contract: fixture.contract,
                                             expectedGeneration: staged.generation)
        #expect(active.activeReceipt?.artifact == artifact)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.layout.claudeRuntimeStateURL)) as? [String: Any])
        if mutation == "missing" {
            json.removeValue(forKey: "activeReceipt")
        } else {
            var receipt = try #require(json["activeReceipt"] as? [String: Any])
            if mutation == "partial" {
                receipt["passedCases"] = ["haikuReply"]
            } else if mutation == "unknownSuite" {
                var contract = try #require(receipt["contract"] as? [String: Any])
                contract["suiteRevision"] = ClaudeRuntimeContract.currentSuiteRevision + 1
                receipt["contract"] = contract
            } else {
                receipt["sourceRuntimeSHA256"] = String(repeating: "b", count: 64)
            }
            json["activeReceipt"] = receipt
        }
        try JSONSerialization.data(withJSONObject: json).write(to: fixture.layout.claudeRuntimeStateURL)
        await #expect(throws: ClaudeRuntimeStoreError.invalidState) { try await fixture.store.load() }
    }
}

@Test("An already activated runtime retains its historical suite receipt across app upgrades")
func retainedRuntimeHistoricalSuiteSurvivesUpgrade() async throws {
    let fixture = try RuntimeStoreFixture(); let store = fixture.store
    let (source, artifact) = try fixture.source("A")
    let staged = try await store.importCandidate(sourceURL: source, artifact: artifact, expectedGeneration: 0)
    let selected = try await store.promote(receipt: fixture.receipt(artifact), contract: fixture.contract,
                                          expectedGeneration: staged.generation)
    // Represent a selection previously activated by the revision-1 application.
    var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.layout.claudeRuntimeStateURL)) as? [String: Any])
    var receipt = try #require(json["activeReceipt"] as? [String: Any])
    var contract = try #require(receipt["contract"] as? [String: Any])
    contract["suiteRevision"] = 1
    receipt["contract"] = contract
    json["activeReceipt"] = receipt
    try JSONSerialization.data(withJSONObject: json).write(to: fixture.layout.claudeRuntimeStateURL)
    let restored = try await fixture.store.load()
    #expect(restored.active == selected.active)
    #expect(restored.generation == selected.generation)
    #expect(restored.activeReceipt?.contract.suiteRevision == 1)
}

@Test("Pruning after promotions keeps exactly the active and previous copies and every check record")
func retainedRuntimePruneKeepsOnlyTheSelection() async throws {
    let fixture = try RuntimeStoreFixture(); let store = fixture.store
    var state = ClaudeRuntimeState()
    var artifacts: [ClaudeRuntimeArtifact] = []
    for version in ["A", "B", "C"] {
        let (source, artifact) = try fixture.source(version)
        state = try await store.importCandidate(sourceURL: source, artifact: artifact, expectedGeneration: state.generation)
        state = try await store.promote(receipt: fixture.receipt(artifact, source: state.active?.sha256),
                                        contract: fixture.contract, expectedGeneration: state.generation)
        artifacts.append(artifact)
    }
    #expect(state.active == artifacts[2] && state.previous == artifacts[1])
    #expect(try await store.pruneRetained(keeping: []) == 0)
    let names = Set(try FileManager.default.contentsOfDirectory(atPath: fixture.layout.claudeRetainedRoot.path))
    #expect(names == [artifacts[1].sha256, artifacts[2].sha256, "Checks"])
    #expect(try await store.checkResult(artifactSHA256: artifacts[0].sha256, contract: fixture.contract)?.status == .passed)
    #expect(try await store.load() == state)
}

@Test("A superseded candidate's copy goes unless kept, and its failed check record stays")
func retainedRuntimePruneRemovesSupersededCandidate() async throws {
    let fixture = try RuntimeStoreFixture(); let store = fixture.store
    let (sourceA, a) = try fixture.source("A")
    var state = try await store.importCandidate(sourceURL: sourceA, artifact: a, expectedGeneration: 0)
    state = try await store.recordResult(ClaudeRuntimeCheckResult(artifactSHA256: a.sha256, contract: fixture.contract,
        status: .failed, message: "fixture failure"), expectedGeneration: state.generation)
    let (sourceB, b) = try fixture.source("B")
    state = try await store.importCandidate(sourceURL: sourceB, artifact: b, expectedGeneration: state.generation)
    let copyA = fixture.layout.claudeRetainedExecutableURL(sha256: a.sha256)
    // A copy still handed out somewhere is kept although the selection dropped it.
    #expect(try await store.pruneRetained(keeping: [a.sha256]) == 0)
    #expect(FileManager.default.fileExists(atPath: copyA.path))
    #expect(try await store.pruneRetained(keeping: []) == 0)
    #expect(!FileManager.default.fileExists(atPath: copyA.deletingLastPathComponent().path))
    #expect(FileManager.default.fileExists(atPath: fixture.layout.claudeRetainedExecutableURL(sha256: b.sha256).path))
    // The remembered failure still stops an automatic probe if A is installed again.
    #expect(try await store.checkResult(artifactSHA256: a.sha256, contract: fixture.contract)?.status == .failed)
    #expect(try await store.load() == state)
}

@Test("Links and unexpected contents in the retained folder are never followed or emptied")
func retainedRuntimePruneNeverFollowsLinks() async throws {
    let fixture = try RuntimeStoreFixture(); let store = fixture.store
    let (sourceA, a) = try fixture.source("A")
    let (sourceB, b) = try fixture.source("B")
    let staged = try await store.importCandidate(sourceURL: sourceA, artifact: a, expectedGeneration: 0)
    _ = try await store.importCandidate(sourceURL: sourceB, artifact: b, expectedGeneration: staged.generation)
    let outside = fixture.container.home.appending(path: "outside", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
    let bait = outside.appending(path: "claude")
    try Data("keep".utf8).write(to: bait)
    let planted = fixture.layout.claudeRetainedRoot.appending(path: String(repeating: "e", count: 64))
    try FileManager.default.createSymbolicLink(at: planted, withDestinationURL: outside)
    let copyA = fixture.layout.claudeRetainedExecutableURL(sha256: a.sha256)
    let extra = copyA.deletingLastPathComponent().appending(path: "extra")
    try FileManager.default.createSymbolicLink(at: extra, withDestinationURL: bait)
    #expect(try await store.pruneRetained(keeping: []) == 2)
    #expect(try Data(contentsOf: bait) == Data("keep".utf8))
    var metadata = stat()
    #expect(lstat(planted.path, &metadata) == 0)
    #expect(metadata.st_mode & S_IFMT == S_IFLNK)
    #expect(lstat(extra.path, &metadata) == 0)
    #expect(metadata.st_mode & S_IFMT == S_IFLNK)
    // A copy with something unexpected inside stays whole, so A can still be imported again.
    #expect(lstat(copyA.path, &metadata) == 0)
    #expect(metadata.st_mode & S_IFMT == S_IFREG)
    #expect(FileManager.default.fileExists(atPath: fixture.layout.claudeRetainedExecutableURL(sha256: b.sha256).path))
    let generation = try await store.load().generation
    let reimported = try await store.importCandidate(sourceURL: sourceA, artifact: a, expectedGeneration: generation)
    #expect(reimported.candidate == a)
}

@Test("Staging and snapshot leftovers from before this process go; newer ones and other names stay")
func retainedRuntimePruneSweepsCrashLeftovers() async throws {
    let fixture = try RuntimeStoreFixture()
    let (source, artifact) = try fixture.source("A")
    var state = try await fixture.store.importCandidate(sourceURL: source, artifact: artifact, expectedGeneration: 0)
    state = try await fixture.store.recordResult(ClaudeRuntimeCheckResult(artifactSHA256: artifact.sha256,
        contract: fixture.contract, status: .failed, message: "fixture failure"), expectedGeneration: state.generation)
    let claude = fixture.layout.claudeRuntimeStateURL.deletingLastPathComponent()
    let checks = fixture.layout.claudeRuntimeChecksRoot.appending(path: artifact.sha256, directoryHint: .isDirectory)
    let stage = fixture.layout.claudeRetainedRoot.appending(path: ".stage-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
    try Data("partial copy".utf8).write(to: stage.appending(path: "claude"))
    let snapshot = claude.appending(path: ".runtime-state-\(UUID().uuidString).tmp")
    let receipt = checks.appending(path: ".runtime-state-\(UUID().uuidString).tmp")
    let foreign = claude.appending(path: ".runtime-state-notes.tmp")
    for url in [snapshot, receipt, foreign] { try Data("{}".utf8).write(to: url) }
    let earlier = ClaudeRuntimeStore(applicationSupportRoot: fixture.root, layout: fixture.layout,
                                     beforePublication: nil, leftoverCutoff: time(nil) - 3_600)
    #expect(try await earlier.pruneRetained(keeping: []) == 0)
    for url in [stage, snapshot, receipt, foreign] { #expect(FileManager.default.fileExists(atPath: url.path)) }
    let later = ClaudeRuntimeStore(applicationSupportRoot: fixture.root, layout: fixture.layout,
                                   beforePublication: nil, leftoverCutoff: time(nil) + 3_600)
    #expect(try await later.pruneRetained(keeping: []) == 0)
    for url in [stage, snapshot, receipt] { #expect(!FileManager.default.fileExists(atPath: url.path)) }
    #expect(FileManager.default.fileExists(atPath: foreign.path))
    #expect(FileManager.default.fileExists(atPath: fixture.layout.claudeRetainedExecutableURL(sha256: artifact.sha256).path))
    #expect(try await fixture.store.checkResult(artifactSHA256: artifact.sha256, contract: fixture.contract)?.status == .failed)
    #expect(try await fixture.store.load() == state)
}
