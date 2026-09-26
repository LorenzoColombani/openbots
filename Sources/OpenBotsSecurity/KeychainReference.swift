import CryptoKit
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

    static let previewGoogleWorkspaceOAuthClient = OpenBotsKeychainService(
        storageValue: "com.lorenzocolombani.openbotsnext.preview.google-oauth-client"
    )
}

public struct OpenBotsKeychainAccount: Hashable, Sendable, CustomStringConvertible {
    let storageValue: String

    public var description: String { storageValue }

    static let controlDatabaseV1 = OpenBotsKeychainAccount(storageValue: "control-database-v1")

    static func connectorBinding(_ bindingID: UUID) -> OpenBotsKeychainAccount {
        OpenBotsKeychainAccount(storageValue: "binding-\(bindingID.uuidString.lowercased())")
    }

    static func googleOAuthClientSecret(_ clientIDHash: String) -> OpenBotsKeychainAccount {
        OpenBotsKeychainAccount(storageValue: "client-secret-\(clientIDHash)")
    }
}

/// An OpenBots-owned reference. There is intentionally no public raw-string initializer,
/// so callers cannot silently repurpose an unrelated ambient Keychain item.
public struct KeychainItemReference: Hashable, Sendable {
    public enum Purpose: Hashable, Sendable {
        case databaseEncryption
        case connectorSecret(connectorID: UUID, bindingID: UUID)
        case googleWorkspaceOAuthClientSecret(clientIDHash: String)
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

    /// The one credential shared by the two Google Workspace rows. The fixed
    /// IDs are namespacing only: the value is an OAuth token envelope written
    /// and read by OpenBots Next's own bundled Google helper. It never reaches
    /// the control database, a prompt, an export, or the legacy OpenBots
    /// Keychain namespace.
    public static let previewGoogleWorkspaceOAuthTokens = previewConnectorSecret(
        connectorID: UUID(uuidString: "4217f1c7-05b7-47c6-9ac9-c14ca1f27435")!,
        bindingID: UUID(uuidString: "c286207d-a3c7-4a44-91e3-70e7a93d036d")!
    )

    /// Signs transient helper capabilities. Separate from the OAuth envelope:
    /// rotating or deleting one class never turns the other into an ambient
    /// credential, and neither shares the legacy app's namespace.
    public static let previewGoogleWorkspaceCapabilityKey = previewConnectorSecret(
        connectorID: UUID(uuidString: "5c1ec8f3-e566-4686-a497-551ab827a77d")!,
        bindingID: UUID(uuidString: "9392facf-712d-4442-a2df-fd97b9fdfeb9")!
    )

    /// The Desktop OAuth client's issued secret, separate from both user OAuth
    /// tokens and the capability-signing key. The public client ID selects the
    /// item through a one-way digest, while the Keychain value is only the
    /// secret bytes imported by the bundled helper.
    public static func previewGoogleWorkspaceOAuthClientSecret(clientID: String)
        -> KeychainItemReference? {
        guard !clientID.isEmpty, clientID.utf8.count <= 512,
              clientID.hasSuffix(".apps.googleusercontent.com"),
              clientID.utf8.allSatisfy({ byte in
                  (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
                      || (byte >= 48 && byte <= 57) || byte == 45 || byte == 46
              }) else { return nil }
        let digest = SHA256.hash(data: Data(clientID.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return KeychainItemReference(
            purpose: .googleWorkspaceOAuthClientSecret(clientIDHash: digest),
            service: .previewGoogleWorkspaceOAuthClient,
            account: .googleOAuthClientSecret(digest)
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
