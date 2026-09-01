import Foundation

public struct OpenBotsKeychainService: Hashable, Sendable, CustomStringConvertible {
    let storageValue: String

    public var description: String { storageValue }

    static let previewDatabase = OpenBotsKeychainService(
        storageValue: "com.lorenzocolombani.openbotsnext.preview.database"
    )

    static func previewConnector(_ connectorID: UUID) -> OpenBotsKeychainService {
        OpenBotsKeychainService(
            storageValue: "com.lorenzocolombani.openbotsnext.preview.connector.\(connectorID.uuidString.lowercased())"
        )
    }
}

public struct OpenBotsKeychainAccount: Hashable, Sendable, CustomStringConvertible {
    let storageValue: String

    public var description: String { storageValue }

    static let controlDatabaseV1 = OpenBotsKeychainAccount(storageValue: "control-database-v1")

    static func connectorBinding(_ bindingID: UUID) -> OpenBotsKeychainAccount {
        OpenBotsKeychainAccount(storageValue: "binding-\(bindingID.uuidString.lowercased())")
    }
}

/// An OpenBots-owned reference. There is intentionally no public raw-string initializer,
/// so callers cannot silently repurpose an unrelated ambient Keychain item.
public struct KeychainItemReference: Hashable, Sendable {
    public enum Purpose: Hashable, Sendable {
        case databaseEncryption
        case connectorSecret(connectorID: UUID, bindingID: UUID)
    }

    public let purpose: Purpose
    public let service: OpenBotsKeychainService
    public let account: OpenBotsKeychainAccount

    public static let previewDatabaseEncryptionKey = KeychainItemReference(
        purpose: .databaseEncryption,
        service: .previewDatabase,
        account: .controlDatabaseV1
    )

    public static func previewConnectorSecret(
        connectorID: UUID,
        bindingID: UUID
    ) -> KeychainItemReference {
        KeychainItemReference(
            purpose: .connectorSecret(connectorID: connectorID, bindingID: bindingID),
            service: .previewConnector(connectorID),
            account: .connectorBinding(bindingID)
        )
    }

    private init(
        purpose: Purpose,
        service: OpenBotsKeychainService,
        account: OpenBotsKeychainAccount
    ) {
        self.purpose = purpose
        self.service = service
        self.account = account
    }
}
