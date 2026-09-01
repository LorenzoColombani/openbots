import Foundation
import OpenBotsDomain

public enum MemoryClaimDecodeStatus: Equatable, Sendable {
    case claims, legacy, unsupported, malformed, oversized
}

public struct MemoryClaimDecodeResult: Equatable, Sendable {
    /// Exact input, including legacy whitespace, malformed bytes and future fields.
    public let originalBytes: Data
    public let status: MemoryClaimDecodeStatus
    /// Only recognized, completely validated v1 artifacts are exposed for active use.
    public let artifact: MemoryClaimArtifact?
    public init(originalBytes: Data, status: MemoryClaimDecodeStatus, artifact: MemoryClaimArtifact? = nil) {
        self.originalBytes = originalBytes; self.status = status; self.artifact = artifact
    }
    public var unrecognizedAssessment: MemoryClaimAssessmentLevel { .unassessed }
}

public enum MemoryClaimCodecError: Error, Equatable, Sendable {
    case invalidArtifact, unsupported, oversized, invalidBinding, claimMissing
}

/// A complete fenced block is the sole claim authority. V1 requires the app's
/// canonical encoding: extra keys, duplicate keys and ambiguous framing cannot
/// silently introduce ignored qualifications. Unsupported bytes remain retained.
public struct MemoryClaimCodec: Sendable {
    public static let header = "<!-- openbots-memory-claims -->\n```json\n"
    public static let footer = "\n```\n"
    public let maximumBytes: Int
    public init(maximumBytes: Int = 16_384) { self.maximumBytes = max(0, maximumBytes) }

    public func encode(_ artifact: MemoryClaimArtifact) throws -> Data {
        guard artifact.hasKnownSemantics else { throw MemoryClaimCodecError.unsupported }
        do { try artifact.validate() } catch { throw MemoryClaimCodecError.invalidArtifact }
        var data = Data(Self.header.utf8)
        data.append(try MemoryClaimDigests.canonicalData(artifact))
        data.append(Data(Self.footer.utf8))
        guard data.count <= maximumBytes else { throw MemoryClaimCodecError.oversized }
        return data
    }

    public func decode(_ bytes: Data, expecting document: MemoryDocument? = nil) -> MemoryClaimDecodeResult {
        func retained(_ status: MemoryClaimDecodeStatus) -> MemoryClaimDecodeResult {
            MemoryClaimDecodeResult(originalBytes: bytes, status: status)
        }
        guard bytes.count <= maximumBytes else { return retained(.oversized) }
        guard let text = String(data: bytes, encoding: .utf8) else { return retained(.malformed) }
        if let document, MemoryClaimDigests.bytes(bytes) != document.contentDigest { return retained(.malformed) }
        guard text.hasPrefix(Self.header) else {
            return retained(text.contains("<!-- openbots-memory-claims") ? .unsupported : .legacy)
        }
        guard text.hasSuffix(Self.footer) else { return retained(.malformed) }
        let payload = Data(text.dropFirst(Self.header.count).dropLast(Self.footer.count).utf8)
        // Inspect only version first so a future schema need not decode as v1.
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let version = object["formatVersion"] as? NSNumber else { return retained(.malformed) }
        guard version == NSNumber(value: 1) else { return retained(.unsupported) }
        guard let artifact = try? JSONDecoder().decode(MemoryClaimArtifact.self, from: payload) else {
            return retained(.malformed)
        }
        guard artifact.hasKnownSemantics else { return retained(.unsupported) }
        guard (try? artifact.validate()) != nil,
              let canonical = try? encode(artifact), canonical == bytes else { return retained(.malformed) }
        if let document {
            guard document.id == artifact.documentID, document.revision == artifact.revision,
                  document.scope == artifact.scope else { return retained(.malformed) }
        }
        return MemoryClaimDecodeResult(originalBytes: bytes, status: .claims, artifact: artifact)
    }

    public func reference(for claim: MemoryClaim, in artifact: MemoryClaimArtifact,
                          contentDigest: String) throws -> MemoryClaimReference {
        guard artifact.claims.contains(claim) else { throw MemoryClaimCodecError.claimMissing }
        let bytes = try encode(artifact)
        guard MemoryClaimDigests.bytes(bytes) == contentDigest else { throw MemoryClaimCodecError.invalidBinding }
        return MemoryClaimReference(documentID: artifact.documentID, documentRevision: artifact.revision,
                                    contentDigest: contentDigest, claimID: claim.id,
                                    claimDigest: try MemoryClaimDigests.claim(claim),
                                    subjectDigest: try MemoryClaimDigests.subject(claim, scope: artifact.scope))
    }

    public func reference(for claimID: MemoryClaimID, in decoded: MemoryClaimDecodeResult) throws -> MemoryClaimReference {
        let checked = decode(decoded.originalBytes)
        guard checked.status == .claims, let artifact = checked.artifact,
              let claim = artifact.claims.first(where: { $0.id == claimID }) else {
            throw MemoryClaimCodecError.claimMissing
        }
        return try reference(for: claim, in: artifact, contentDigest: MemoryClaimDigests.bytes(checked.originalBytes))
    }
}
