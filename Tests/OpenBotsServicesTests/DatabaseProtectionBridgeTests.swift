import Foundation
import OpenBotsPersistence
import OpenBotsSecurity
import Testing
@testable import OpenBotsServices

@Test("Decision 0008 selects ordinary SQLite through one immutable preview receipt")
func previewDatabaseProtectionDecisionIsExplicit() {
    #expect(PreviewDatabaseProtectionDecision.selection == .ordinarySQLite)
    #expect(
        PreviewDatabaseProtectionDecision.receipt.decisionID
            == UUID(uuidString: "C84EEA6F-5D19-4C7F-8778-5A5DAB9CB6BC")!
    )
    #expect(
        PreviewDatabaseProtectionDecision.receipt.selectedAt
            == Date(timeIntervalSince1970: 1_788_026_784)
    )
    #expect(PreviewDatabaseProtectionDecision.receipt.rationaleVersion == 2)
}

@Test("Database protection bridge never invents or downgrades the selected mode")
func databaseProtectionBridgePreservesMode() throws {
    let receipt = try ProtectionDecisionReceipt(
        decisionID: UUID(uuidString: "86000000-0000-0000-0000-000000000001")!,
        selectedAt: Date(timeIntervalSince1970: 860),
        rationaleVersion: 1
    )
    let bridge = DatabaseProtectionBridge()

    let ordinary = bridge.persistencePlan(for: .ordinarySQLite, decision: receipt)
    let encrypted = bridge.persistencePlan(for: .sqlCipher, decision: receipt)

    #expect(ordinary.mode == .ordinarySQLite)
    #expect(ordinary.decision == receipt)
    #expect(encrypted.mode == .sqlCipher)
    #expect(encrypted.decision == receipt)
    guard case let .sqlCipher(_, keyID) = encrypted else {
        Issue.record("Expected the SQLCipher plan to remain encrypted")
        return
    }
    #expect(keyID == .previewControlDatabaseV1)
}
