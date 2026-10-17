import Foundation

public enum GoogleWorkspacePublicConfigurationError: Error, Equatable, Sendable {
    case invalidRecord, alreadyConfigured, readbackMismatch, configurationChanged
}

/// Public OAuth identity only. Tokens and desktop-client secrets keep their
/// existing Keychain formats and identities; this record never contains either.
public struct GoogleWorkspacePublicConfiguration: Codable, Equatable, Sendable {
    public static let metadataKey = "google_workspace_public_configuration_v1"
    public static let maximumEncodedByteCount = 1_024
    public let version: Int
    public let clientID: String

    public init(version: Int = 1, clientID: String) throws {
        self.version = version
        self.clientID = clientID
        try validate()
    }

    public static func validClientID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && value.hasSuffix(".apps.googleusercontent.com")
            && value.utf8.allSatisfy { byte in
                (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
                    || (byte >= 48 && byte <= 57) || byte == 45 || byte == 46
            }
    }

    public func validate() throws {
        guard version == 1, Self.validClientID(clientID) else {
            throw GoogleWorkspacePublicConfigurationError.invalidRecord
        }
    }

    public func encodedData() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumEncodedByteCount else {
            throw GoogleWorkspacePublicConfigurationError.invalidRecord
        }
        return data
    }

    public static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumEncodedByteCount else {
            throw GoogleWorkspacePublicConfigurationError.invalidRecord
        }
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == ["version", "clientID"] else {
                throw GoogleWorkspacePublicConfigurationError.invalidRecord
            }
            let record = try JSONDecoder().decode(Self.self, from: data)
            try record.validate()
            return record
        } catch { throw GoogleWorkspacePublicConfigurationError.invalidRecord }
    }
}

public protocol GoogleWorkspacePublicConfigurationRepository: Sendable {
    /// Absence is distinct from malformed or unreadable state, which throws.
    func loadGoogleWorkspacePublicConfiguration() async throws -> GoogleWorkspacePublicConfiguration?
    /// Insert only. A concurrent winner or any existing value is never replaced.
    func seedGoogleWorkspacePublicConfiguration(_ configuration: GoogleWorkspacePublicConfiguration) async throws
    /// Compare and swap: replaces the record only while it still equals
    /// `expected`, otherwise throws `configurationChanged` and writes nothing.
    func replaceGoogleWorkspacePublicConfiguration(_ expected: GoogleWorkspacePublicConfiguration,
                                                   with replacement: GoogleWorkspacePublicConfiguration) async throws
}
