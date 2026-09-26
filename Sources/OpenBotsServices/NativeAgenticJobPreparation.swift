import CryptoKit
import Darwin
import Foundation
import OpenBotsAgenticRuntime
import OpenBotsContent
import OpenBotsDomain
import OpenBotsExecutionRules
import OpenBotsRuntime
import OpenBotsSecurity

public enum NativeAgenticJobFailure: Error, Equatable, Sendable {
    case accessDisabled, accessChanged, setupRequired, subscriptionRequired, policyNotAdmitted
    case unsafeWorkspace, changedInstallation, noCompletedReport, invalidJob, expiredApproval
}

public protocol AgenticJobPreparing: Sendable {
    /// `webCapabilities` are the web tools admitted for this process; the
    /// conversation role must always receive an empty set.
    func prepare(request: WorkRequest, role: FirstToolJobProcessRole, sessionID: UUID,
                 webCapabilities: Set<AgenticWebCapability>) async throws -> FirstToolJobLaunchPlan
    func report(runID: OpenBotsDomain.RunID) async throws -> AgenticJobReport
}

public struct AgenticJobReport: Equatable, Sendable {
    public let text: String
    public let sha256: String
    public let sourceURL: URL
    public init(text: String, sha256: String, sourceURL: URL) {
        self.text = text; self.sha256 = sha256; self.sourceURL = sourceURL
    }
}

/// Preparation for the approved first sample-folder job. Called only after its
/// native user consent. It never signs in or supplies API-billing credentials.
public actor NativeAgenticJobPreparation: AgenticJobPreparing {
    private struct Eligibility { let hash: String; let profile: String; let expiresAt: Date }
    private let layout: PreviewStorageLayout
    private let root: @Sendable () async -> VerifiedOwnedRoot?
    private let status: any ClaudeStatusChecking
    private let policy: any ClaudeTextPolicyInspecting
    private var workspaces: [OpenBotsDomain.RunID: NativeAgenticJobWorkspace] = [:]
    private var eligibility: [OpenBotsDomain.RunID: Eligibility] = [:]
    private var workerDirectories: [OpenBotsDomain.RunID: URL] = [:]

    public init(layout: PreviewStorageLayout,
                applicationSupportRoot: @escaping @Sendable () async -> VerifiedOwnedRoot?,
                status: any ClaudeStatusChecking = NativeClaudeStatusChecker(),
                policy: any ClaudeTextPolicyInspecting = NativeClaudeTextPolicyInspector()) {
        self.layout = layout; root = applicationSupportRoot; self.status = status; self.policy = policy
    }

    public nonisolated static func folder(runID: OpenBotsDomain.RunID) -> URL {
        URL(fileURLWithPath: "/private/tmp/OpenBotsJob-\(runID.rawValue.uuidString.lowercased()).noindex", isDirectory: true)
    }

    public func prepare(request: WorkRequest, role: FirstToolJobProcessRole, sessionID: UUID,
                        webCapabilities: Set<AgenticWebCapability>) async throws -> FirstToolJobLaunchPlan {
        try Task.checkCancellation()
        guard let support = await root() else { throw NativeAgenticJobFailure.setupRequired }
        let admission = try await FirstToolJobAdmission(layout: layout, applicationSupportRoot: support).inspect()
        guard policy.inspect(profileURL: layout.claudeCLIProfileRoot) == .admitted else {
            throw NativeAgenticJobFailure.policyNotAdmitted
        }
        let target = try ClaudeConnectionTarget(executableURL: URL(fileURLWithPath: admission.installation.resolvedPath),
            expectedExecutableSHA256: admission.installation.sha256, profileURL: layout.claudeCLIProfileRoot,
            workingDirectoryURL: layout.claudeCLIProfileRoot, temporaryDirectoryURL: layout.claudeCLIProfileRoot,
            homeDirectoryURL: layout.homeDirectory)
        if let checked = eligibility[request.runID] {
            guard checked.hash == admission.installation.sha256, checked.profile == target.profileURL.path,
                  checked.expiresAt > Date() else { throw NativeAgenticJobFailure.changedInstallation }
        } else {
            guard case .eligible = await status.checkStatus(target: target) else {
                throw NativeAgenticJobFailure.subscriptionRequired
            }
            eligibility[request.runID] = Eligibility(hash: admission.installation.sha256,
                profile: target.profileURL.path, expiresAt: Date().addingTimeInterval(180))
        }
        try Task.checkCancellation()
        let jobRoot = Self.folder(runID: request.runID)
        if workspaces[request.runID] == nil {
            workspaces[request.runID] = try NativeAgenticJobWorkspace(root: jobRoot)
        }
        guard var workspace = workspaces[request.runID] else { throw NativeAgenticJobFailure.unsafeWorkspace }
        var published = false
        defer { if !published { workspaces[request.runID] = workspace } }
        try workspace.verify()
        let folderName = role == .worker ? "worker" : "conversation-\(sessionID.uuidString.lowercased())"
        let processRoot = jobRoot.appending(path: folderName, directoryHint: .isDirectory)
        try workspace.createDirectory(processRoot)
        let paths = try AgenticProbePaths(root: processRoot, configurationDirectory: layout.claudeCLIProfileRoot,
            homeDirectory: layout.homeDirectory, claudeExecutable: target.executableURL)
        try workspace.createDirectory(paths.workingDirectory)
        try workspace.createDirectory(paths.temporaryDirectory)
        let plan = try FirstToolJobLaunchPreparation.makePlan(admission: admission, paths: paths, role: role,
            teammateID: OpenBotsExecutionRules.TeammateID(request.teammateID.rawValue),
            runID: OpenBotsExecutionRules.RunID(request.runID.rawValue), sessionID: sessionID, model: "sonnet",
            webCapabilities: role == .worker ? webCapabilities : [])
        try workspace.writeNew(plan.settingsJSON, to: paths.settingsFile)
        try workspace.writeNew(plan.mcpJSON, to: paths.mcpFile)
        if role == .worker {
            try workspace.writeNew(Data("id,environment,amount\n1,production,10\n2,test,99\n3,production,30\n".utf8),
                to: paths.workingDirectory.appending(path: "sample.csv"))
            workerDirectories[request.runID] = paths.workingDirectory
        }
        try workspace.verify()
        guard try workspace.readRegular(paths.settingsFile, maximum: 131_072) == plan.settingsJSON,
              try workspace.readRegular(paths.mcpFile, maximum: 131_072) == plan.mcpJSON,
              policy.inspect(profileURL: target.profileURL) == .admitted else { throw NativeAgenticJobFailure.unsafeWorkspace }
        try Task.checkCancellation()
        // Every individual process gets another current static identity check.
        workspaces[request.runID] = workspace
        published = true
        let current = try await FirstToolJobAdmission(layout: layout, applicationSupportRoot: support).inspect()
        guard current.installation == admission.installation, current.profile == admission.profile else {
            throw NativeAgenticJobFailure.changedInstallation
        }
        guard let currentWorkspace = workspaces[request.runID] else { throw NativeAgenticJobFailure.unsafeWorkspace }
        try currentWorkspace.verify()
        return plan
    }

    public func report(runID: OpenBotsDomain.RunID) throws -> AgenticJobReport {
        guard let workspace = workspaces[runID], let work = workerDirectories[runID] else {
            throw NativeAgenticJobFailure.noCompletedReport
        }
        try workspace.verify()
        let url = work.appending(path: "report.md")
        let bytes = try workspace.readRegular(url, maximum: 65_536)
        guard !bytes.isEmpty, let text = String(data: bytes, encoding: .utf8), !text.utf8.contains(0) else {
            throw NativeAgenticJobFailure.noCompletedReport
        }
        return AgenticJobReport(text: text,
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), sourceURL: url)
    }

}
