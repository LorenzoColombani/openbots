import Foundation

public enum DatabaseProtectionSelection: String, Codable, Sendable {
    case ordinarySQLite
    case sqlCipher
}

public struct DatabaseKeyPolicy: Sendable {
    public init() {}

    public func keyReference(for selection: DatabaseProtectionSelection) -> KeychainItemReference? {
        switch selection {
        case .ordinarySQLite:
            return nil
        case .sqlCipher:
            return .previewDatabaseEncryptionKey
        }
    }
}

public enum DatabaseKeyCoordinatorError: Error, Equatable, Sendable {
    case invalidStoredKeyLength(actual: Int)
    case invalidGeneratedKeyLength(actual: Int)
}

/// Resolves a key only for an explicitly selected encrypted database. Ordinary SQLite
/// returns before consulting either the generator or Keychain client.
public actor DatabaseKeyCoordinator {
    private let keychain: any KeychainClient
    private let generateKey: @Sendable () throws -> Data
    private let policy: DatabaseKeyPolicy

    public init(
        keychain: any KeychainClient,
        policy: DatabaseKeyPolicy = DatabaseKeyPolicy(),
        generateKey: @escaping @Sendable () throws -> Data
    ) {
        self.keychain = keychain
        self.policy = policy
        self.generateKey = generateKey
    }

    public func loadOrCreateKey(for selection: DatabaseProtectionSelection) async throws -> Data? {
        guard let reference = policy.keyReference(for: selection) else { return nil }
        if let existing = try await keychain.read(reference) {
            guard existing.count == 32 else {
                throw DatabaseKeyCoordinatorError.invalidStoredKeyLength(actual: existing.count)
            }
            return existing
        }
        let generated = try generateKey()
        guard generated.count == 32 else {
            throw DatabaseKeyCoordinatorError.invalidGeneratedKeyLength(actual: generated.count)
        }
        try await keychain.store(generated, at: reference)
        return generated
    }
}
