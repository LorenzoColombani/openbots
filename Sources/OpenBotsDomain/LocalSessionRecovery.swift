import Foundation

public enum LocalSessionSaveOutcome: String, Codable, Equatable, Sendable {
    case open, saved, incomplete
}

public enum LocalSessionRecoveryError: Error, Equatable, Sendable {
    case invalidRecord, staleSession, invalidTransition
}

/// One small app-owned marker, not a work journal or a promise of lossless saving.
/// An open marker on the next launch means only that a final save was unconfirmed.
public struct LocalSessionRecoveryRecord: Codable, Equatable, Sendable {
    public static let maximumEncodedByteCount = 1_024
    public let version: Int
    public let id: UUID
    public let startedAt: Date
    public let endedAt: Date?
    public let status: LocalSessionSaveOutcome

    public init(version: Int = 1, id: UUID, startedAt: Date, endedAt: Date? = nil,
                status: LocalSessionSaveOutcome) throws {
        self.version = version
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        try validate()
    }

    public func validate() throws {
        guard version == 1, startedAt.timeIntervalSince1970.isFinite else {
            throw LocalSessionRecoveryError.invalidRecord
        }
        switch status {
        case .open:
            guard endedAt == nil else { throw LocalSessionRecoveryError.invalidRecord }
        case .saved, .incomplete:
            guard let endedAt, endedAt.timeIntervalSince1970.isFinite, endedAt >= startedAt else {
                throw LocalSessionRecoveryError.invalidRecord
            }
        }
    }

    public func encodedData() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumEncodedByteCount else { throw LocalSessionRecoveryError.invalidRecord }
        return data
    }

    public static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumEncodedByteCount else { throw LocalSessionRecoveryError.invalidRecord }
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys).isSubset(of: ["version", "id", "startedAt", "endedAt", "status"]),
                  Set(["version", "id", "startedAt", "status"]).isSubset(of: Set(object.keys)) else {
                throw LocalSessionRecoveryError.invalidRecord
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            let record = try decoder.decode(Self.self, from: data)
            try record.validate()
            return record
        } catch { throw LocalSessionRecoveryError.invalidRecord }
    }
}

public protocol LocalSessionRecoveryRepository: Sendable {
    /// Read the prior marker and atomically install this new open session.
    /// Malformed prior data must not be replaced or silently treated as absent.
    func beginLocalSession(id: UUID, at: Date) async throws -> LocalSessionRecoveryRecord?
    /// Only the exact current open session can be finished; a prior session
    /// cannot finish a later launch, even if its saving task completes late.
    func finishLocalSession(id: UUID, outcome: LocalSessionSaveOutcome, at: Date) async throws
}
