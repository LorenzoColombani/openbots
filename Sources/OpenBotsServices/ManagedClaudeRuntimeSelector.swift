import Foundation
import OpenBotsSecurity

/// Normal consumers receive `.active`. The candidate seam is reserved for the
/// separate compatibility profile's official setup flow and compatibility suite.
/// Neither selection can fall back to the independently installed global CLI.
public struct ManagedClaudeRuntimeSelector: ClaudeInstallationInspecting {
    public enum Purpose: Sendable { case active, compatibilityCandidate }
    private let service: ManagedClaudeRuntimeService
    private let purpose: Purpose

    public init(service: ManagedClaudeRuntimeService, purpose: Purpose = .active) {
        self.service = service
        self.purpose = purpose
    }

    public func inspectInstallation() async -> ClaudeInstallationInspection {
        await service.inspectSelectedRuntime(purpose: purpose)
    }
}
