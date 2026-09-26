import Foundation
import OpenBotsPersistence
import OpenBotsSecurity

/// The explicit product decision for the preview database: ordinary SQLite.
/// Keeping the selection and immutable receipt together prevents dependency failures from
/// inventing a different mode at runtime.
public enum PreviewDatabaseProtectionDecision {
    public static let selection: DatabaseProtectionSelection = .ordinarySQLite

    public static let receipt: ProtectionDecisionReceipt = {
        // A numeric instant avoids locale or parser drift.
        try! ProtectionDecisionReceipt(
            decisionID: UUID(uuidString: "C84EEA6F-5D19-4C7F-8778-5A5DAB9CB6BC")!,
            selectedAt: Date(timeIntervalSince1970: 1_788_026_784),
            rationaleVersion: 2
        )
    }()
}
