import Foundation

/// Cross-actor admission for the brief, reversible update preparation window.
/// Accepted operations hold a lease until their actual persistence completes.
public final class ApplicationUpdateGate: @unchecked Sendable {
    public static let shared = ApplicationUpdateGate()
    private let lock = NSLock()
    private var owner: UUID?
    private var operations: Set<UUID> = []
    public init() {}
    public var allowsWork: Bool { lock.withLock { owner == nil } }
    public var hasOperations: Bool { lock.withLock { !operations.isEmpty } }

    public final class Operation: Sendable {
        private let gate: ApplicationUpdateGate
        private let id: UUID
        fileprivate init(gate: ApplicationUpdateGate, id: UUID) { self.gate = gate; self.id = id }
        deinit { gate.end(id) }
    }

    public func beginOperation() -> Operation? {
        lock.withLock {
            guard owner == nil else { return nil }
            let id = UUID()
            operations.insert(id)
            return Operation(gate: self, id: id)
        }
    }
    private func end(_ id: UUID) { _ = lock.withLock { operations.remove(id) } }
    public func freeze(_ token: UUID) -> Bool {
        lock.withLock {
            guard owner == nil, operations.isEmpty else { return false }
            owner = token
            return true
        }
    }
    public func release(_ token: UUID) { lock.withLock { if owner == token { owner = nil } } }
}

/// Captured from control storage, then freshly checked at download and install.
/// Only an exact durable/effective match can authorize an ID-free candidate.
public struct GoogleWorkspaceUpdateConfiguration: Equatable, Sendable {
    public let clientID: String?
    public let durableClientID: String?

    public init(clientID: String? = nil, durableClientID: String? = nil) {
        self.clientID = clientID
        self.durableClientID = durableClientID
    }
}
