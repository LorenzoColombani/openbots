import CryptoKit
import Foundation
import OpenBotsDomain

public enum ProfilePhotoServiceError: Error, Equatable, Sendable {
    case unavailable
    case invalidReceipt
    case contentMismatch
    case conflictingAppearanceChoices
}

public protocol ProfilePhotoValidating: Sendable {
    func validatePhoto(id: ProfileAssetID) async throws
}

/// App-owned photo coordination only. Constructor is inert. The importer
/// receives one explicitly picked source; immutable bytes are published before
/// metadata. An interrupted metadata write may leave an unreferenced owned
/// image, never a profile pointing at a partially written image. No external
/// source cleanup, upload, secret access or automatic asset deletion occurs.
public actor ProfilePhotoService: ProfilePhotoValidating {
    public typealias Importer = @Sendable (URL, ProfileAssetID) async throws -> ProfilePhotoAsset
    public typealias Reader = @Sendable (ProfilePhotoAsset) async throws -> Data
    private let repository: any ProfilePhotoRepository
    private let importer: Importer
    private let reader: Reader
    private let uuidGenerator: any UUIDGenerator

    public init(
        repository: any ProfilePhotoRepository,
        importer: @escaping Importer,
        reader: @escaping Reader,
        uuidGenerator: any UUIDGenerator = SystemUUIDGenerator()
    ) {
        self.repository = repository
        self.importer = importer
        self.reader = reader
        self.uuidGenerator = uuidGenerator
    }

    public func importPhoto(from exactSource: URL) async throws -> ProfilePhotoAsset {
        try Task.checkCancellation()
        let id = ProfileAssetID(uuidGenerator.next())
        let asset = try await importer(exactSource, id)
        guard asset.id == id else { throw ProfilePhotoServiceError.invalidReceipt }
        _ = try await verifiedBytes(asset)
        try Task.checkCancellation()
        try await repository.insertAsset(asset)
        return asset
    }

    public func imageData(id: ProfileAssetID) async throws -> Data {
        guard let asset = try await repository.asset(id: id), asset.id == id else {
            throw ProfilePhotoServiceError.unavailable
        }
        return try await verifiedBytes(asset)
    }

    public func validatePhoto(id: ProfileAssetID) async throws {
        _ = try await imageData(id: id)
    }

    private func verifiedBytes(_ asset: ProfilePhotoAsset) async throws -> Data {
        let data = try await reader(asset)
        guard data.count == asset.byteCount,
              data.count <= ProfilePhotoAsset.maximumByteCount,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == asset.sha256 else {
            throw ProfilePhotoServiceError.contentMismatch
        }
        return data
    }
}
