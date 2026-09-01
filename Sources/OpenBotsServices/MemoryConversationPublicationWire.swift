import Foundation
import OpenBotsDomain

extension MemoryConversationPublicationService {
    /// Version 1 wire shape is exactly {version,units:[{kind,references:[...]}]}.
    /// No prose, strength, template or receipt supplied by the provider is read.
    public static func decodeCandidate(_ data: Data) throws -> MemoryPublicationCandidate {
        guard !data.isEmpty, data.count <= MemoryPublicationLimits.candidateBytes else {
            throw MemoryConversationPublicationError.boundsExceeded
        }
        do {
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(root.keys) == ["version", "units"],
                  let rawUnits = root["units"] as? [[String: Any]],
                  rawUnits.count <= MemoryPublicationLimits.units else {
                throw MemoryConversationPublicationError.invalidCandidate
            }
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.version == 1 else { throw MemoryConversationPublicationError.invalidCandidate }
            var units: [MemoryPublicationUnit] = []
            for (index, raw) in rawUnits.enumerated() {
                guard Set(raw.keys) == ["kind", "references"],
                      let references = raw["references"] as? [[String: Any]],
                      references.count <= MemoryPublicationLimits.referencesPerUnit,
                      let kind = MemoryPublicationUnitKind(rawValue: envelope.units[index].kind),
                      kind != .explanationSourcesUnavailable, kind != .explanationLineageUnverifiable else {
                    throw MemoryConversationPublicationError.invalidCandidate
                }
                for reference in references {
                    guard Set(reference.keys) == ["documentID", "documentRevision", "contentDigest", "claimID", "claimDigest", "subjectDigest"] else {
                        throw MemoryConversationPublicationError.invalidCandidate
                    }
                }
                let decoded = envelope.units[index].references
                guard Set(decoded).count == decoded.count,
                      decoded.allSatisfy({ $0.documentRevision > 0 && validDigest($0.contentDigest)
                          && validDigest($0.claimDigest) && validDigest($0.subjectDigest) }) else {
                    throw MemoryConversationPublicationError.invalidCandidate
                }
                units.append(.init(kind: kind, references: decoded))
            }
            return .init(units: units)
        } catch let error as MemoryConversationPublicationError { throw error }
        catch { throw MemoryConversationPublicationError.invalidCandidate }
    }

    private struct Envelope: Decodable {
        let version: UInt16
        let units: [Unit]
        struct Unit: Decodable { let kind: String; let references: [MemoryClaimReference] }
    }
}
