import OpenBotsDomain

extension SQLiteStore: ProfilePhotoRepository {
    public func asset(id: ProfileAssetID) async throws -> ProfilePhotoAsset? {
        guard let row = try query(
            sql: "SELECT id,width,height,byte_count,sha256,length(CAST(sha256 AS BLOB)) AS digest_bytes FROM profile_photo_assets WHERE id=?;",
            bindings: [.text(id.persistedValue)]
        ).first else { return nil }
        // SQLite's text accessor uses C strings. Validate the stored byte
        // length too, so a corrupted digest cannot hide trailing data after
        // an embedded NUL and appear to be a valid 64-character prefix.
        guard try row.integer("digest_bytes") == 64 else {
            throw DomainValidationError.invalid(
                field: "profile photo digest", reason: "stored digest must contain exactly 64 ASCII bytes"
            )
        }
        guard let width = Int(exactly: try row.integer("width")),
              let height = Int(exactly: try row.integer("height")),
              let byteCount = Int(exactly: try row.integer("byte_count")) else {
            throw SQLiteStoreError.invalidRow(reason: "profile photo dimensions or byte count exceed integer bounds")
        }
        return try ProfilePhotoAsset(
            id: parseID(ProfileAssetID.self, row.text("id")),
            width: width, height: height, byteCount: byteCount,
            sha256: row.text("sha256")
        )
    }

    public func insertAsset(_ asset: ProfilePhotoAsset) async throws {
        try transaction {
            guard try query(
                sql: "SELECT id FROM profile_photo_assets WHERE id=?;",
                bindings: [.text(asset.id.persistedValue)]
            ).isEmpty else {
                throw RepositoryError.alreadyExists(entity: "profile photo asset", id: asset.id.persistedValue)
            }
            // No replace/upsert path. The normalized file is immutable and its
            // metadata must never be retargeted under an existing identity.
            _ = try execute(
                sql: "INSERT INTO profile_photo_assets(id,width,height,byte_count,sha256) VALUES (?,?,?,?,?);",
                bindings: [
                    .text(asset.id.persistedValue), .integer(Int64(asset.width)),
                    .integer(Int64(asset.height)), .integer(Int64(asset.byteCount)),
                    .text(asset.sha256),
                ]
            )
        }
    }
}
