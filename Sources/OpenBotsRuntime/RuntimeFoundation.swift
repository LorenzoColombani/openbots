import Foundation

/// Marker for the executor-independent runtime module. The disabled
/// `TeammateExecutor` adapter is added at integration once the Domain protocol
/// has landed; no process launch exists in this target before that boundary.
public enum OpenBotsRuntimeFoundation: Sendable {
    case executorUnavailable
}
