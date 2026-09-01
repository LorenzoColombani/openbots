import Foundation
import OpenBotsContent
import OpenBotsDomain
import OpenBotsRuntime
import OpenBotsSecurity

public enum ClaudeTextLaunchPreparation: Sendable {
    case ready(ClaudeConnectionTarget)
    case refused(ClaudeTextTurnProblem)
}

public protocol ClaudeTextLaunchPreparing: Sendable {
    func prepareTextLaunch(runID: UUID) async -> ClaudeTextLaunchPreparation
    func prepareTextLaunch(runID: UUID, model: String) async -> ClaudeTextLaunchPreparation
    func prepareTextLaunch(runID: UUID, selection: ClaudeExecutionSelection) async -> ClaudeTextLaunchPreparation
}

public extension ClaudeTextLaunchPreparing {
    /// Older adapters cannot prove Max eligibility for Opus/Fable. Keep their existing
    /// Sonnet/Haiku preparation usable without granting new metered authority.
    func prepareTextLaunch(runID: UUID, model: String) async -> ClaudeTextLaunchPreparation {
        guard ClaudeTextOnlyRequest.supportedModels.contains(model), !ClaudeTextModelTierPolicy.requiresMax(model) else {
            return .refused(.modelUnavailable)
        }
        return await prepareTextLaunch(runID: runID)
    }

    /// Compatibility cannot silently drop non-default selectors or infer a
    /// subscription allowance. Adapters must opt into full-selection admission.
    func prepareTextLaunch(runID: UUID, selection: ClaudeExecutionSelection) async -> ClaudeTextLaunchPreparation {
        if let problem = ClaudeTextModelTierPolicy.selectionProblem(selection) { return .refused(problem) }
        guard selection.effort == "default" else { return .refused(.effortUnavailable) }
        guard selection.contextWindow == "default" else { return .refused(.contextWindowUnavailable) }
        return await prepareTextLaunch(runID: runID, model: selection.model)
    }
}

/// Admission for an explicit new text send, never on construction or app launch.
/// It neither signs in nor reads Claude configuration/credential contents.
public struct NativeClaudeTextLaunchPreparer: ClaudeTextLaunchPreparing {
    private let layout: PreviewStorageLayout
    private let supportRoot: @Sendable () async -> VerifiedOwnedRoot?
    private let connection: any ClaudeConnectionPreparing
    private let policy: any ClaudeTextPolicyInspecting
    private let status: any ClaudeStatusChecking

    public init(layout: PreviewStorageLayout,
                applicationSupportRoot: @escaping @Sendable () async -> VerifiedOwnedRoot?,
                connection: any ClaudeConnectionPreparing,
                policy: any ClaudeTextPolicyInspecting = NativeClaudeTextPolicyInspector(),
                status: any ClaudeStatusChecking = NativeClaudeStatusChecker()) {
        self.layout = layout
        supportRoot = applicationSupportRoot
        self.connection = connection
        self.policy = policy
        self.status = status
    }

    public func prepareTextLaunch(runID: UUID) async -> ClaudeTextLaunchPreparation {
        await prepareTextLaunch(runID: runID, model: "sonnet")
    }

    public func prepareTextLaunch(runID: UUID, model: String) async -> ClaudeTextLaunchPreparation {
        await prepareTextLaunch(runID: runID,
            selection: ClaudeExecutionSelection(model: model, effort: "default", contextWindow: "default"))
    }

    public func prepareTextLaunch(runID: UUID, selection: ClaudeExecutionSelection) async -> ClaudeTextLaunchPreparation {
        guard !Task.isCancelled else { return .refused(.unavailable) }
        if let problem = ClaudeTextModelTierPolicy.selectionProblem(selection) { return .refused(problem) }
        guard case let .ready(local, target) = await connection.prepareConnection(),
              local.installation == .verified, local.profile == .metadataVerified,
              target.profileURL == layout.claudeCLIProfileRoot,
              !Task.isCancelled else { return .refused(.setupRequired) }
        guard policy.inspect(profileURL: target.profileURL) == .admitted else {
            return .refused(.managedPolicyPresentOrUnknown)
        }
        guard case let .eligible(tier) = await status.checkStatus(target: target), !Task.isCancelled else {
            return .refused(.subscriptionNotVerified)
        }
        // Max covers these Opus choices. This is tier admission only, never a
        // statement about remaining allowance or independently verified billing.
        guard !ClaudeTextModelTierPolicy.requiresMax(selection.model) || tier == .max else {
            return .refused(.modelUnavailable)
        }
        guard let root = await supportRoot(), !Task.isCancelled else { return .refused(.setupRequired) }
        do {
            let layout = layout
            let directories = try await Task.detached(priority: .userInitiated) {
                try ClaudeTextRunDirectoryStore().create(runID: runID,
                    applicationSupportRoot: root, layout: layout)
            }.value
            guard !Task.isCancelled,
                  policy.inspect(profileURL: target.profileURL) == .admitted else {
                return .refused(.managedPolicyPresentOrUnknown)
            }
            let scoped = try ClaudeConnectionTarget(executableURL: target.executableURL,
                expectedExecutableSHA256: target.expectedExecutableSHA256,
                profileURL: target.profileURL,
                workingDirectoryURL: directories.workingDirectory,
                temporaryDirectoryURL: directories.temporaryDirectory,
                homeDirectoryURL: target.homeDirectoryURL)
            return .ready(scoped)
        } catch { return .refused(.setupRequired) }
    }
}

private enum ClaudeTextModelTierPolicy {
    static func selectionProblem(_ selection: ClaudeExecutionSelection) -> ClaudeTextTurnProblem? {
        guard ClaudeTextOnlyRequest.supportedModels.contains(selection.model) else { return .modelUnavailable }
        guard selection.effort == "default" || ClaudeEffortPolicy.supportedValues(for: selection.model).contains(selection.effort) else {
            return .effortUnavailable
        }
        guard ClaudeContextWindowPolicy.supportedValues(for: selection.model).contains(selection.contextWindow) else {
            return .contextWindowUnavailable
        }
        // Official model-config (2026-08-31): Sonnet 4.6 [1m] requires credits
        // on every plan. Fable can silently bill credits in -p after its included
        // allowance. No allowance-only route is proven here, so refuse it without
        // reading or changing billing settings. Saved preferences stay untouched.
        if selection.model == "claude-fable-5" { return .modelUnavailable }
        if selection.model == "claude-sonnet-4-6", selection.contextWindow == "long" { return .contextWindowUnavailable }
        return nil
    }

    static func requiresMax(_ model: String) -> Bool {
        ["claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8", "claude-opus-5", "claude-fable-5"].contains(model)
    }
}
