import Foundation

/// Immutable metadata for app-owned bytes. Neither the source path nor file
/// contents are persisted here; an attachment belongs to exactly one chat.
public struct AttachmentAsset: Equatable, Sendable, Codable, Identifiable {
    /// Current local-preview policy, not a Claude/runtime upload limit.
    public static let provisionalMaximumByteCount: Int64 = 100 * 1_024 * 1_024
    public let id: AttachmentID
    public let conversationID: ConversationID
    public let displayName: String
    public let typeIdentifier: String
    public let byteCount: Int64
    public let sha256: String
    public let createdAt: Date

    public init(
        id: AttachmentID, conversationID: ConversationID, displayName: String,
        typeIdentifier: String, byteCount: Int64, sha256: String, createdAt: Date
    ) throws {
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              displayName.utf8.count <= 255, displayName != ".", displayName != "..",
              !displayName.contains("/"),
              !displayName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw DomainValidationError.invalid(field: "attachment name", reason: "must be a bounded filename, not a path")
        }
        guard !typeIdentifier.isEmpty, typeIdentifier.utf8.count <= 255,
              typeIdentifier.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46
              }) else {
            throw DomainValidationError.invalid(field: "attachment type", reason: "must be a bounded type identifier")
        }
        guard (0...Self.provisionalMaximumByteCount).contains(byteCount) else {
            throw DomainValidationError.invalid(field: "attachment byte count", reason: "exceeds the provisional local size policy")
        }
        guard sha256.utf8.count == 64,
              sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw DomainValidationError.invalid(field: "attachment digest", reason: "must be 64 lowercase hexadecimal characters")
        }
        guard createdAt.timeIntervalSince1970.isFinite else {
            throw DomainValidationError.invalid(field: "attachment timestamp", reason: "must be finite")
        }
        self.id = id
        self.conversationID = conversationID
        self.displayName = displayName
        self.typeIdentifier = typeIdentifier
        self.byteCount = byteCount
        self.sha256 = sha256
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, conversationID, displayName, typeIdentifier, byteCount, sha256, createdAt
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(AttachmentID.self, forKey: .id),
            conversationID: values.decode(ConversationID.self, forKey: .conversationID),
            displayName: values.decode(String.self, forKey: .displayName),
            typeIdentifier: values.decode(String.self, forKey: .typeIdentifier),
            byteCount: values.decode(Int64.self, forKey: .byteCount),
            sha256: values.decode(String.self, forKey: .sha256),
            createdAt: values.decode(Date.self, forKey: .createdAt)
        )
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.conversationID == rhs.conversationID &&
        lhs.displayName.utf8.elementsEqual(rhs.displayName.utf8) &&
        lhs.typeIdentifier.utf8.elementsEqual(rhs.typeIdentifier.utf8) &&
        lhs.byteCount == rhs.byteCount && lhs.sha256 == rhs.sha256 &&
        lhs.createdAt.timeIntervalSince1970 == rhs.createdAt.timeIntervalSince1970
    }
}

public struct AttachmentDraftSnapshot: Equatable, Sendable {
    public static let maximumAttachments = 24
    public let conversationID: ConversationID
    /// Zero denotes an untouched empty draft. Removals leave a revisioned tombstone.
    public let revision: Int64
    public let attachments: [AttachmentAsset]

    public init(conversationID: ConversationID, revision: Int64, attachments: [AttachmentAsset]) {
        self.conversationID = conversationID
        self.revision = revision
        self.attachments = attachments
    }
}
