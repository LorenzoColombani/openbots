import Foundation

public enum DatabaseProtectionMode: String, Codable, CaseIterable, Sendable {
    case sqlCipher
    case ordinarySQLite
}

/// Records the product decision that selected a protection mode. Constructing an adapter is not a decision.
public struct ProtectionDecisionReceipt: Codable, Equatable, Sendable {
    public let decisionID: UUID
    public let selectedAt: Date
    public let rationaleVersion: UInt16

    public init(decisionID: UUID, selectedAt: Date, rationaleVersion: UInt16) throws {
        guard rationaleVersion > 0 else {
            throw DatabaseProtectionError.invalidDecisionReceipt
        }
        self.decisionID = decisionID
        self.selectedAt = selectedAt
        self.rationaleVersion = rationaleVersion
    }
}

/// Closed persistence-side identity for an encryption key. OpenBotsSecurity maps this to
/// its purpose-typed Keychain reference; Persistence never receives service/account strings.
public enum DatabaseEncryptionKeyID: String, Codable, Sendable {
    case previewControlDatabaseV1
}

public protocol DatabaseKeyMaterialProvider: Sendable {
    func keyMaterial(for keyID: DatabaseEncryptionKeyID) async throws -> Data
}

/// An explicit persistence plan. This name is intentionally distinct from Security's UI selection.
/// Services must match the two modes and bridge only `.previewControlDatabaseV1` to the
/// Security-owned `.previewDatabaseEncryptionKey` reference.
public enum PersistenceProtectionPlan: Equatable, Sendable {
    case sqlCipher(decision: ProtectionDecisionReceipt, keyID: DatabaseEncryptionKeyID)
    case ordinarySQLite(decision: ProtectionDecisionReceipt)

    public var mode: DatabaseProtectionMode {
        switch self {
        case .sqlCipher: .sqlCipher
        case .ordinarySQLite: .ordinarySQLite
        }
    }

    public var decision: ProtectionDecisionReceipt {
        switch self {
        case let .sqlCipher(decision, _), let .ordinarySQLite(decision): decision
        }
    }
}

public enum DatabaseProtectionError: Error, Equatable, Sendable {
    case invalidDecisionReceipt
    case adapterUnavailable(requested: DatabaseProtectionMode)
    case storedModeMissing
    case storedModeMismatch(stored: String, requested: DatabaseProtectionMode)
    case decisionReceiptMismatch
}
