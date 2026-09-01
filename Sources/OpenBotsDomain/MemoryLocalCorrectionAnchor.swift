import Foundation

/// One already displayed qualified unit explicitly referenced by the user's
/// correction. It disambiguates that target; it never certifies a full inventory.
public struct MemoryLocalCorrectionAnchor: Codable, Equatable, Sendable {
    public let receiptID: UUID
    public let reference: MemoryClaimReference

    public init(receiptID: UUID, reference: MemoryClaimReference) {
        self.receiptID = receiptID; self.reference = reference
    }
}
