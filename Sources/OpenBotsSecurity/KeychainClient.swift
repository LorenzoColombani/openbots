import Foundation

public protocol KeychainClient: Sendable {
    func read(_ reference: KeychainItemReference) async throws -> Data?
    func store(_ secret: Data, at reference: KeychainItemReference) async throws
    func delete(_ reference: KeychainItemReference) async throws
}

public struct KeychainOperation: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case read
        case store(byteCount: Int)
        case delete
    }

    public let reference: KeychainItemReference
    public let kind: Kind
}

/// Deterministic test/development fake. It never calls Security.framework and its
/// operation log deliberately records byte counts, never secret bytes.
public actor InMemoryKeychainClient: KeychainClient {
    private var items: [KeychainItemReference: Data]
    private var operations: [KeychainOperation] = []

    public init(seed: [KeychainItemReference: Data] = [:]) {
        items = seed
    }

    public func read(_ reference: KeychainItemReference) async throws -> Data? {
        operations.append(KeychainOperation(reference: reference, kind: .read))
        return items[reference]
    }

    public func store(_ secret: Data, at reference: KeychainItemReference) async throws {
        operations.append(
            KeychainOperation(reference: reference, kind: .store(byteCount: secret.count))
        )
        items[reference] = secret
    }

    public func delete(_ reference: KeychainItemReference) async throws {
        operations.append(KeychainOperation(reference: reference, kind: .delete))
        items.removeValue(forKey: reference)
    }

    public func recordedOperations() -> [KeychainOperation] {
        operations
    }

    public func contains(_ reference: KeychainItemReference) -> Bool {
        items[reference] != nil
    }
}
