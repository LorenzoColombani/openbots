/// Closed, path-free startup failures that the UI can map to stable recovery
/// guidance without presenting arbitrary implementation error text.
public enum LaunchRecoveryIssue: String, Codable, CaseIterable, Equatable, Sendable {
    case installationReceiptUnavailable
    case ownedRootVerificationFailed
    case databaseProtectionUnavailable
    case databaseOpenFailed
    case databaseValidationFailed
}

/// The complete startup-readiness vocabulary exposed to presentation code.
public enum LaunchReadinessState: Equatable, Sendable {
    case notConfigured
    case opening
    case ready
    case recovery(LaunchRecoveryIssue)
}

/// Executor-independent inspection seam. Implementations own the translation
/// from lower-level failures into the closed recovery vocabulary.
public protocol LaunchReadinessInspecting: Sendable {
    func inspectReadiness() async -> LaunchReadinessState
}

/// Small forwarding boundary for startup presentation models. Constructing it
/// only retains the injected inspector and performs no inspection or other I/O.
public struct LaunchReadinessService: Sendable {
    private let inspector: any LaunchReadinessInspecting

    public init(inspector: any LaunchReadinessInspecting) {
        self.inspector = inspector
    }

    public func inspectReadiness() async -> LaunchReadinessState {
        await inspector.inspectReadiness()
    }
}

/// Deterministic no-I/O implementation for previews and tests.
public struct FixedLaunchReadinessInspector: LaunchReadinessInspecting {
    public let state: LaunchReadinessState

    public init(state: LaunchReadinessState) {
        self.state = state
    }

    public func inspectReadiness() async -> LaunchReadinessState {
        state
    }
}
