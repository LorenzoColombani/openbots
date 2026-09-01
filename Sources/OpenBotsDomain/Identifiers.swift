import Foundation

/// A stable identity whose value is persisted and never derived from a display name.
public protocol OpenBotsIdentifier: Codable, Hashable, Sendable, CustomStringConvertible {
    var rawValue: UUID { get }
    init(_ rawValue: UUID)
}

public extension OpenBotsIdentifier {
    var description: String { rawValue.uuidString.lowercased() }
    var persistedValue: String { description }
}

private func decodeUUID<T: OpenBotsIdentifier>(
    _ type: T.Type,
    from decoder: any Decoder
) throws -> T {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    guard let uuid = UUID(uuidString: value) else {
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Expected a UUID string for \(T.self)."
        )
    }
    return T(uuid)
}

private func encodeUUID<T: OpenBotsIdentifier>(
    _ value: T,
    to encoder: any Encoder
) throws {
    var container = encoder.singleValueContainer()
    try container.encode(value.persistedValue)
}

public struct TeammateID: OpenBotsIdentifier {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws { self = try decodeUUID(Self.self, from: decoder) }
    public func encode(to encoder: any Encoder) throws { try encodeUUID(self, to: encoder) }
}

/// Stable identity for a provisional hiring conversation. This identifier is
/// discarded when hiring is confirmed and never becomes teammate authority.
public struct HiringDraftID: OpenBotsIdentifier {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws { self = try decodeUUID(Self.self, from: decoder) }
    public func encode(to encoder: any Encoder) throws { try encodeUUID(self, to: encoder) }
}

/// Stable identity for one conversational turn inside a hiring draft.
public struct HiringTurnID: OpenBotsIdentifier {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws { self = try decodeUUID(Self.self, from: decoder) }
    public func encode(to encoder: any Encoder) throws { try encodeUUID(self, to: encoder) }
}

public struct ProjectID: OpenBotsIdentifier {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws { self = try decodeUUID(Self.self, from: decoder) }
    public func encode(to encoder: any Encoder) throws { try encodeUUID(self, to: encoder) }
}

public struct TeamID: OpenBotsIdentifier {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws { self = try decodeUUID(Self.self, from: decoder) }
    public func encode(to encoder: any Encoder) throws { try encodeUUID(self, to: encoder) }
}

public struct ConversationID: OpenBotsIdentifier {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws { self = try decodeUUID(Self.self, from: decoder) }
    public func encode(to encoder: any Encoder) throws { try encodeUUID(self, to: encoder) }
}

public struct MessageID: OpenBotsIdentifier {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws { self = try decodeUUID(Self.self, from: decoder) }
    public func encode(to encoder: any Encoder) throws { try encodeUUID(self, to: encoder) }
}

public struct MessagePartID: OpenBotsIdentifier {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws { self = try decodeUUID(Self.self, from: decoder) }
    public func encode(to encoder: any Encoder) throws { try encodeUUID(self, to: encoder) }
}

public struct MemoryDocumentID: OpenBotsIdentifier {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws { self = try decodeUUID(Self.self, from: decoder) }
    public func encode(to encoder: any Encoder) throws { try encodeUUID(self, to: encoder) }
}

public struct AttachmentID: OpenBotsIdentifier {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws { self = try decodeUUID(Self.self, from: decoder) }
    public func encode(to encoder: any Encoder) throws { try encodeUUID(self, to: encoder) }
}

public struct ArtifactID: OpenBotsIdentifier {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws { self = try decodeUUID(Self.self, from: decoder) }
    public func encode(to encoder: any Encoder) throws { try encodeUUID(self, to: encoder) }
}

public struct ProfileAssetID: OpenBotsIdentifier {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws { self = try decodeUUID(Self.self, from: decoder) }
    public func encode(to encoder: any Encoder) throws { try encodeUUID(self, to: encoder) }
}

public struct RunID: OpenBotsIdentifier {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws { self = try decodeUUID(Self.self, from: decoder) }
    public func encode(to encoder: any Encoder) throws { try encodeUUID(self, to: encoder) }
}

public struct CapabilityGrantID: OpenBotsIdentifier {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws { self = try decodeUUID(Self.self, from: decoder) }
    public func encode(to encoder: any Encoder) throws { try encodeUUID(self, to: encoder) }
}

public struct ApprovalID: OpenBotsIdentifier {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws { self = try decodeUUID(Self.self, from: decoder) }
    public func encode(to encoder: any Encoder) throws { try encodeUUID(self, to: encoder) }
}

public struct HandoffID: OpenBotsIdentifier {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws { self = try decodeUUID(Self.self, from: decoder) }
    public func encode(to encoder: any Encoder) throws { try encodeUUID(self, to: encoder) }
}

/// Stable identity for the one receiver leg in the initial directed handoff
/// contract. A later fan-out design may add multiple legs without changing the
/// handoff's own identity or reusing a receiver's result as another leg.
public struct HandoffLegID: OpenBotsIdentifier {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws { self = try decodeUUID(Self.self, from: decoder) }
    public func encode(to encoder: any Encoder) throws { try encodeUUID(self, to: encoder) }
}
