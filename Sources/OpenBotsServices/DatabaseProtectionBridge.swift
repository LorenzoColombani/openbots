import OpenBotsPersistence
import OpenBotsSecurity

/// Converts one explicit product-level selection into the closed persistence
/// plan. It never invents a default and never handles key bytes.
public struct DatabaseProtectionBridge: Sendable {
    public init() {}

    public func persistencePlan(
        for selection: OpenBotsSecurity.DatabaseProtectionSelection,
        decision: ProtectionDecisionReceipt
    ) -> PersistenceProtectionPlan {
        switch selection {
        case .ordinarySQLite:
            .ordinarySQLite(decision: decision)
        case .sqlCipher:
            .sqlCipher(decision: decision, keyID: .previewControlDatabaseV1)
        }
    }
}
