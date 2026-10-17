import CryptoKit
import Foundation
import OpenBotsContent
import OpenBotsDomain
import OpenBotsExecutionRules
import OpenBotsSecurity
import Testing
@testable import OpenBotsAgenticRuntime

private struct RetainedAdmissionSignature: ClaudeStaticSignatureChecking {
    static let identity = ClaudeStaticSignatureIdentity(identifier: "com.anthropic.claude-code",
        teamIdentifier: "Q6L2SF6YDW", codeDirectoryHash: String(repeating: "a", count: 40))
    func checkSignature(at executableURL: URL, openedDescriptor: Int32) -> ClaudeStaticSignatureCheck {
        .verified(Self.identity)
    }
}

private struct RetainedAdmissionObservation: ClaudeInstallationInspecting {
    let value: ClaudeInstallationInspection
    func inspectInstallation() async -> ClaudeInstallationInspection { value }
}

@Test("Older jobs accept exact retained provenance and cannot substitute another path or hash")
func retainedRuntimeAdmitsOlderJobsWithoutGlobalLauncher() async throws {
    let id = UUID().uuidString
    let home = URL(fileURLWithPath: "/private/tmp/RetainedAdmissionHome-\(id).noindex")
    let scratch = URL(fileURLWithPath: "/private/tmp/RetainedAdmissionJob-\(id).noindex")
    defer { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: scratch) }
    let layout = PreviewStorageLayout(homeDirectory: home, systemTemporaryDirectory: URL(fileURLWithPath: "/private/tmp"))
    let installationID = UUID(), rootID = UUID()
    let root = layout.applicationSupportRoot.url
    let bytes = Data([0xcf, 0xfa, 0xed, 0xfe]) + Data("retained fixture".utf8)
    let artifact = ClaudeRuntimeArtifact(version: "2.1.300", sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
        signatureIdentifier: "com.anthropic.claude-code", teamIdentifier: "Q6L2SF6YDW",
        codeDirectoryHash: String(repeating: "a", count: 40))
    let executable = layout.claudeRetainedExecutableURL(sha256: artifact.sha256)
    try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    let marker = root.appending(path: ".openbots-root.json")
    try JSONSerialization.data(withJSONObject: [
        "formatVersion": 1, "bundleIdentifier": OpenBotsPreviewIdentity.bundleIdentifier,
        "installationID": installationID.uuidString, "rootID": rootID.uuidString, "kind": "applicationSupport"
    ]).write(to: marker)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
    try bytes.write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let owned = try OwnedRootVerifier().verify(layout.applicationSupportRoot,
        expectedInstallationID: installationID, expectedRootID: rootID)
    try ClaudeProfileProvisioner().ensureExists(applicationSupportRoot: owned, layout: layout)
    let inspector = RetainedClaudeInstallationInspector(applicationSupportRootURL: root,
        installationID: installationID, rootID: rootID, artifact: artifact,
        signatureChecker: RetainedAdmissionSignature())
    let receipt = try await FirstToolJobAdmission(layout: layout, applicationSupportRoot: owned,
                                                  installationInspector: inspector).inspect()
    #expect(receipt.installation.verifiedRetainedProvenance != nil)
    #expect(!FileManager.default.fileExists(atPath: home.appending(path: ".local/bin/claude").path))
    let paths = try AgenticProbePaths(root: scratch, configurationDirectory: layout.claudeCLIProfileRoot,
                                     homeDirectory: home, claudeExecutable: executable)
    let plan = try FirstToolJobLaunchPreparation.makePlan(admission: receipt, paths: paths, role: .conversation,
        teammateID: OpenBotsExecutionRules.TeammateID(UUID()), runID: OpenBotsExecutionRules.RunID(UUID()),
        sessionID: UUID(), model: "sonnet")
    #expect(plan.paths.claudeExecutable == executable)
    #expect(plan.environment["DISABLE_UPDATES"] == "1")
    let wrongPaths = try AgenticProbePaths(root: scratch, configurationDirectory: layout.claudeCLIProfileRoot,
        homeDirectory: home, claudeExecutable: executable.deletingLastPathComponent().appending(path: "other"))
    #expect(throws: FirstToolJobLaunchPreparationError.installationMismatch) {
        try FirstToolJobLaunchPreparation.makePlan(admission: receipt, paths: wrongPaths, role: .conversation,
            teammateID: OpenBotsExecutionRules.TeammateID(UUID()), runID: OpenBotsExecutionRules.RunID(UUID()),
            sessionID: UUID(), model: "sonnet")
    }
    var fabricated = await inspector.inspectInstallation()
    fabricated = .init(state: .verified, details: .init(requestedPath: executable.path,
        resolvedPath: executable.path, versionFilename: artifact.version, sha256: artifact.sha256,
        signature: RetainedAdmissionSignature.identity, fileIdentity: fabricated.details.fileIdentity))
    await #expect(throws: FirstToolJobAdmissionError.malformedInstallation) {
        try await FirstToolJobAdmission(layout: layout, applicationSupportRoot: owned,
            installationInspector: RetainedAdmissionObservation(value: fabricated)).inspect()
    }
}
