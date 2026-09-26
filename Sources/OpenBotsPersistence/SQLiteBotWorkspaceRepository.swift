import Foundation
import OpenBotsDomain

/// One `app_metadata` row per bot, keyed `bot_workspace_v1.<teammate id>`, holding
/// the bot's own folder and the folders the user added as one JSON record.
/// No schema change: a bot without a row has never worked on the Mac.
private let botWorkspaceKeyPrefix = "bot_workspace_v1"

extension SQLiteStore: BotWorkspaceRepository {
    public func loadBotWorkspace(teammateID: TeammateID) async throws -> BotWorkspaceRecord? {
        try Task.checkCancellation()
        let rows = try query(sql: "SELECT value FROM app_metadata WHERE key=?;",
                             bindings: [.text("\(botWorkspaceKeyPrefix).\(teammateID.persistedValue)")])
        guard let row = rows.first else { return nil }
        let text = try row.text("value")
        guard text.utf8.count <= 65_536 else { return nil }
        return try JSONDecoder().decode(BotWorkspaceRecord.self, from: Data(text.utf8))
    }

    public func saveBotWorkspace(_ record: BotWorkspaceRecord, teammateID: TeammateID) async throws {
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(record)
        guard data.count <= 65_536, let text = String(data: data, encoding: .utf8) else {
            throw RepositoryError.unavailable(reason: "Bot workspace record too large")
        }
        _ = try execute(sql: """
            INSERT INTO app_metadata(key,value) VALUES (?,?)
            ON CONFLICT(key) DO UPDATE SET value=excluded.value;
            """, bindings: [.text("\(botWorkspaceKeyPrefix).\(teammateID.persistedValue)"), .text(text)])
    }
}
