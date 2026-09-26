import Foundation
import OpenBotsDomain

/// One `app_metadata` row per bot waiting to set itself up, keyed
/// `bot_self_setup_v1.<teammate id>`, its value the placeholder name the bot
/// was born with. The setup deletes it, so the table lists only waiting bots.
private let selfSetupKeyPrefix = "bot_self_setup_v1"

extension SQLiteStore: BotSelfSetupRepository {
    public func pendingSelfSetupName(teammateID: TeammateID) async throws -> String? {
        try Task.checkCancellation()
        let rows = try query(sql: "SELECT value FROM app_metadata WHERE key=?;",
                             bindings: [.text("\(selfSetupKeyPrefix).\(teammateID.persistedValue)")])
        return try rows.first?.text("value")
    }

    public func setPendingSelfSetup(teammateID: TeammateID, placeholderName: String?) async throws {
        try Task.checkCancellation()
        try writePendingSelfSetup(teammateID: teammateID, placeholderName: placeholderName)
    }

    /// The row itself, for a caller already inside a transaction.
    func writePendingSelfSetup(teammateID: TeammateID, placeholderName: String?) throws {
        let key = "\(selfSetupKeyPrefix).\(teammateID.persistedValue)"
        if let placeholderName {
            _ = try execute(sql: """
                INSERT INTO app_metadata(key,value) VALUES (?,?)
                ON CONFLICT(key) DO UPDATE SET value=excluded.value;
                """, bindings: [.text(key), .text(placeholderName)])
        } else {
            _ = try execute(sql: "DELETE FROM app_metadata WHERE key=?;", bindings: [.text(key)])
        }
    }
}
