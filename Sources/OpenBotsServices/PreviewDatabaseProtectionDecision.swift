import Foundation
import OpenBotsPersistence
import OpenBotsSecurity

/// The explicit product decision recorded in decision 0008. Keeping the
/// selection and immutable receipt together prevents dependency failures from
/// inventing a different mode at runtime.
public enum PreviewDatabaseProtectionDecision {
    public static let selection: DatabaseProtectionSelection = .ordinarySQLite

    public static let receipt: ProtectionDecisionReceipt = {
        // 2026-08-29T18:06:24Z. A numeric instant avoids locale or parser drift.
        try! ProtectionDecisionReceipt(
            decisionID: UUID(uuidString: "C84EEA6F-5D19-4C7F-8778-5A5DAB9CB6BC")!,
            selectedAt: Date(timeIntervalSince1970: 1_788_026_784),
            rationaleVersion: 2
        )
    }()
}
