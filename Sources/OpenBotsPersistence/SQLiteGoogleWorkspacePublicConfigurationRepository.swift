import Foundation
import OpenBotsDomain

extension SQLiteStore: GoogleWorkspacePublicConfigurationRepository {
    public func loadGoogleWorkspacePublicConfiguration() async throws -> GoogleWorkspacePublicConfiguration? {
        try readGoogleWorkspacePublicConfiguration()
    }

    public func seedGoogleWorkspacePublicConfiguration(_ configuration: GoogleWorkspacePublicConfiguration) async throws {
        let data = try configuration.encodedData()
        try transaction {
            guard try readGoogleWorkspacePublicConfiguration() == nil else {
                throw GoogleWorkspacePublicConfigurationError.alreadyConfigured
            }
            let changed = try execute(sql: "INSERT INTO app_metadata(key,value) VALUES (?,?);",
                bindings: [.text(GoogleWorkspacePublicConfiguration.metadataKey), .text(String(decoding: data, as: UTF8.self))])
            guard changed == 1 else { throw GoogleWorkspacePublicConfigurationError.readbackMismatch }
        }
    }

    public func replaceGoogleWorkspacePublicConfiguration(_ expected: GoogleWorkspacePublicConfiguration,
                                                          with replacement: GoogleWorkspacePublicConfiguration) async throws {
        let data = try replacement.encodedData()
        try transaction {
            guard try readGoogleWorkspacePublicConfiguration() == expected else {
                throw GoogleWorkspacePublicConfigurationError.configurationChanged
            }
            let changed = try execute(sql: "UPDATE app_metadata SET value=? WHERE key=?;",
                bindings: [.text(String(decoding: data, as: UTF8.self)), .text(GoogleWorkspacePublicConfiguration.metadataKey)])
            guard changed == 1 else { throw GoogleWorkspacePublicConfigurationError.readbackMismatch }
        }
    }

    private func readGoogleWorkspacePublicConfiguration() throws -> GoogleWorkspacePublicConfiguration? {
        guard let row = try query(sql: """
            SELECT length(CAST(value AS BLOB)) AS byte_count,
                   CASE WHEN length(CAST(value AS BLOB))<=? THEN value ELSE NULL END AS bounded_value
            FROM app_metadata WHERE key=?;
            """, bindings: [.integer(Int64(GoogleWorkspacePublicConfiguration.maximumEncodedByteCount)),
                            .text(GoogleWorkspacePublicConfiguration.metadataKey)]).first else { return nil }
        let count = try row.integer("byte_count")
        guard count > 0, count <= Int64(GoogleWorkspacePublicConfiguration.maximumEncodedByteCount),
              let json = try row.optionalText("bounded_value") else {
            throw GoogleWorkspacePublicConfigurationError.invalidRecord
        }
        return try GoogleWorkspacePublicConfiguration.decode(Data(json.utf8))
    }
}
