import CryptoKit
import Foundation
import OpenBotsSecurity

public enum GoogleWorkspaceService: String, Codable, Equatable, Sendable {
    case gmail, calendar, drive
    /// Its own capability: a read-and-draft launch cannot send, and a send
    /// launch cannot read.
    case gmailSend = "gmail_send"
}

/// The installed private app boundary. A copied helper or a process merely
/// named like the app somewhere else cannot mint lifecycle/capability actions.
public enum GoogleWorkspaceInstalledCallerPolicy {
    public static let appPath = "/Applications/OpenBots Next.app/Contents/MacOS/OpenBots Next"
    public static let helperPath = "/Applications/OpenBots Next.app/Contents/MacOS/openbots-google-helper"

    public static func acceptsLifecycleCaller(helperPath: String, parentPath: String?) -> Bool {
        helperPath == Self.helperPath && parentPath == appPath
    }

    public static func acceptsOperationalHelper(path: String) -> Bool { path == helperPath }
}

public enum GoogleWorkspaceCapabilityError: Error, Equatable, Sendable, LocalizedError {
    case unavailable, malformed, expired, wrongService, wrongConnection, wrongProcess

    public var errorDescription: String? {
        switch self {
        case .unavailable: "The Google connector capability could not be created."
        case .malformed: "The Google connector refused an invalid capability."
        case .expired: "The Google connector capability expired with its turn."
        case .wrongService: "That capability belongs to a different Google connector."
        case .wrongConnection: "The Google account changed after this connector started."
        case .wrongProcess: "The Google helper was not launched by the OpenBots turn that authorized it."
        }
    }
}

/// A signed, short-lived proof minted only for a connector launch whose caller
/// is the installed OpenBots app. It is not a Google credential: the payload
/// contains only the service, connection instance, issuer process and expiry.
///
/// The signature key stays in a separate Keychain item. A copied token is also
/// bound to the issuing app process being in the helper's live ancestor chain,
/// so an unrelated same-user process cannot replay a value it saw in the
/// private transient MCP configuration.
public struct GoogleWorkspaceHelperCapability: Sendable {
    public struct Payload: Codable, Equatable, Sendable {
        public let version: Int
        public let service: GoogleWorkspaceService
        public let clientID: String
        public let connectionID: UUID
        public let issuerPID: Int32
        public let issuedAt: Date
        public let expiresAt: Date
        public let nonce: UUID
    }

    private static let maximumTokenBytes = 4_096
    private static let keyBytes = 32
    private static let maximumLifetime: TimeInterval = 6 * 60 * 60
    private let keychain: any KeychainClient

    public init(keychain: any KeychainClient) { self.keychain = keychain }

    public func mint(service: GoogleWorkspaceService, clientID: String, connectionID: UUID,
                     issuerPID: Int32, now: Date = Date(), lifetime: TimeInterval = 60 * 60) async throws -> String {
        guard GoogleWorkspaceCredential.validClientID(clientID), issuerPID > 1,
              lifetime > 0, lifetime <= Self.maximumLifetime else {
            throw GoogleWorkspaceCapabilityError.malformed
        }
        let payload = Payload(version: 1, service: service, clientID: clientID,
            connectionID: connectionID, issuerPID: issuerPID, issuedAt: now,
            expiresAt: now.addingTimeInterval(lifetime), nonce: UUID())
        let payloadData = try JSONEncoder().encode(payload)
        let key = try await signingKey(createIfMissing: true)
        let authentication = HMAC<SHA256>.authenticationCode(for: payloadData, using: key)
        let token = payloadData.base64URL + "." + Data(authentication).base64URL
        guard token.utf8.count <= Self.maximumTokenBytes else {
            throw GoogleWorkspaceCapabilityError.malformed
        }
        return token
    }

    public func validate(_ token: String, service: GoogleWorkspaceService, clientID: String,
                         connectionID: UUID? = nil, ancestorPIDs: Set<Int32>,
                         now: Date = Date()) async throws -> Payload {
        guard token.utf8.count <= Self.maximumTokenBytes else {
            throw GoogleWorkspaceCapabilityError.malformed
        }
        let pieces = token.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 2, let payloadData = Data(base64URL: String(pieces[0])),
              let supplied = Data(base64URL: String(pieces[1])), supplied.count == SHA256.byteCount,
              let payload = try? JSONDecoder().decode(Payload.self, from: payloadData),
              payload.version == 1, payload.clientID == clientID else {
            throw GoogleWorkspaceCapabilityError.malformed
        }
        let key = try await signingKey(createIfMissing: false)
        guard HMAC<SHA256>.isValidAuthenticationCode(supplied, authenticating: payloadData, using: key)
        else { throw GoogleWorkspaceCapabilityError.malformed }
        guard payload.service == service else { throw GoogleWorkspaceCapabilityError.wrongService }
        if let connectionID, payload.connectionID != connectionID {
            throw GoogleWorkspaceCapabilityError.wrongConnection
        }
        guard payload.issuedAt <= now.addingTimeInterval(5), payload.expiresAt > now,
              payload.expiresAt.timeIntervalSince(payload.issuedAt) <= Self.maximumLifetime else {
            throw GoogleWorkspaceCapabilityError.expired
        }
        guard ancestorPIDs.contains(payload.issuerPID) else {
            throw GoogleWorkspaceCapabilityError.wrongProcess
        }
        return payload
    }

    private func signingKey(createIfMissing: Bool) async throws -> SymmetricKey {
        let reference = KeychainItemReference.previewGoogleWorkspaceCapabilityKey
        if let data = try await keychain.read(reference) {
            guard data.count == Self.keyBytes else { throw GoogleWorkspaceCapabilityError.unavailable }
            return SymmetricKey(data: data)
        }
        guard createIfMissing else { throw GoogleWorkspaceCapabilityError.unavailable }
        var bytes = [UInt8](repeating: 0, count: Self.keyBytes)
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max, using: &generator) }
        let data = Data(bytes)
        try await keychain.store(data, at: reference)
        return SymmetricKey(data: data)
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL: String) {
        guard base64URL.utf8.allSatisfy({ byte in
            (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
                || (byte >= 48 && byte <= 57) || byte == 45 || byte == 95
        }) else { return nil }
        var value = base64URL.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        self.init(base64Encoded: value)
    }
}
