import Foundation
import OpenBotsDomain

/// The production executor is intentionally unavailable: no trust
/// architecture for it exists yet. Keeping this behind `TeammateExecutor` lets
/// the rest of the app work without representing chat-only behavior as the
/// finished product.
public actor PendingArchitectureExecutor: TeammateExecutor {
    public init() {}

    public func start(_ request: WorkRequest) async throws {
        throw ExecutorUnavailableError()
    }

    public func steer(
        _ input: SteeringInput,
        into runID: RunID
    ) async throws -> SteeringSubmission {
        throw ExecutorUnavailableError()
    }

    public func events(
        for runID: RunID
    ) async -> AsyncThrowingStream<WorkEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: ExecutorUnavailableError())
        }
    }

    public func requestStop(runID: RunID) async throws {
        throw ExecutorUnavailableError()
    }
}

public struct ExecutorUnavailableError: Error, Equatable, LocalizedError, Sendable {
    public init() {}

    public var errorDescription: String? {
        "Agentic execution is not configured in this preview yet."
    }
}
