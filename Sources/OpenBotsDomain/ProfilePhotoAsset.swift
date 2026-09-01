/// Immutable metadata for a normalized, app-owned PNG. Original filenames,
/// user paths, image bytes and source metadata do not cross this boundary.
public struct ProfilePhotoAsset: Equatable, Sendable, Codable {
    public static let maximumDimension = 512
    public static let maximumByteCount = 4 * 1_024 * 1_024

    public let id: ProfileAssetID
    public let width: Int
    public let height: Int
    public let byteCount: Int
    public let sha256: String

    public init(id: ProfileAssetID, width: Int, height: Int, byteCount: Int, sha256: String) throws {
        guard (1...Self.maximumDimension).contains(width),
              (1...Self.maximumDimension).contains(height) else {
            throw DomainValidationError.invalid(
                field: "profile photo dimensions", reason: "must be between 1 and 512 pixels"
            )
        }
        guard (1...Self.maximumByteCount).contains(byteCount) else {
            throw DomainValidationError.invalid(
                field: "profile photo byte count", reason: "must be positive and no larger than 4 MiB"
            )
        }
        guard sha256.utf8.count == 64,
              sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw DomainValidationError.invalid(
                field: "profile photo digest", reason: "must contain exactly 64 lowercase hexadecimal characters"
            )
        }
        self.id = id
        self.width = width
        self.height = height
        self.byteCount = byteCount
        self.sha256 = sha256
    }

    private enum CodingKeys: String, CodingKey {
        case id, width, height, byteCount, sha256
    }

    /// Decoding must not bypass the same bounds enforced at normal creation.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(ProfileAssetID.self, forKey: .id),
            width: values.decode(Int.self, forKey: .width),
            height: values.decode(Int.self, forKey: .height),
            byteCount: values.decode(Int.self, forKey: .byteCount),
            sha256: values.decode(String.self, forKey: .sha256)
        )
    }
}

public protocol ProfilePhotoRepository: Sendable {
    func asset(id: ProfileAssetID) async throws -> ProfilePhotoAsset?
    /// Insert-only: a reused identity is a collision, even for identical data.
    func insertAsset(_ asset: ProfilePhotoAsset) async throws
}
