import Foundation
import Security

public protocol KeychainClient: Sendable {
    func read(_ reference: KeychainItemReference) async throws -> Data?
    func store(_ secret: Data, at reference: KeychainItemReference) async throws
    func delete(_ reference: KeychainItemReference) async throws
}

/// The production Keychain bridge.
///
/// It uses a generic-password item in the user's local login Keychain. The
/// service and account can only come from `KeychainItemReference`, so callers
/// cannot turn this into an ambient-Keychain reader. No secret bytes enter an
/// error, diagnostic, label, or command line.
public struct SystemKeychainClient: KeychainClient {
    public enum Failure: Error, Equatable, Sendable {
        case unexpectedResult
        case securityStatus(Int32)
    }

    public init() {}

    public func read(_ reference: KeychainItemReference) async throws -> Data? {
        var query = baseQuery(reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.securityStatus(status) }
        guard let data = result as? Data else { throw Failure.unexpectedResult }
        return data
    }

    public func store(_ secret: Data, at reference: KeychainItemReference) async throws {
        let query = baseQuery(reference)
        let update = [kSecValueData as String: secret]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw Failure.securityStatus(status) }

        var addition = query
        addition[kSecValueData as String] = secret
        addition[kSecAttrLabel as String] = "OpenBots Next connector credential"
        let added = SecItemAdd(addition as CFDictionary, nil)
        guard added == errSecSuccess else { throw Failure.securityStatus(added) }
    }

    public func delete(_ reference: KeychainItemReference) async throws {
        let status = SecItemDelete(baseQuery(reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.securityStatus(status)
        }
    }

    private func baseQuery(_ reference: KeychainItemReference) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: reference.service.description,
            kSecAttrAccount as String: reference.account.description,
            // Explicitly local. Connector credentials must never join an
            // iCloud Keychain or another synced authority store.
            kSecAttrSynchronizable as String: false,
        ]
    }
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
