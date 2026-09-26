import Foundation
import OpenBotsDomain

/// One `app_metadata` row per switch that is on, keyed
/// `agentic_web_switch_v1.app.<capability>` for an app-wide switch and
/// `agentic_web_switch_v1.bot.<teammate id>.<capability>` for a bot's grant.
/// The "work" capability (files and shell) shares the rows and the prefix.
/// Turning a switch off deletes its row, so the table only ever lists what is
/// on and an archived bot's grant sits untouched until the bot is back.
private let webSwitchKeyPrefix = "agentic_web_switch_v1"
private let webSwitchOnValue = "on"

extension SQLiteStore: AgenticWebSwitchRepository {
    public func loadWebSwitches() async throws -> AgenticWebSwitchSnapshot {
        try Task.checkCancellation()
        // GLOB, not LIKE: an underscore in the prefix would be a LIKE wildcard.
        let rows = try query(sql: "SELECT key FROM app_metadata WHERE key GLOB ? AND value=? ORDER BY key;",
                             bindings: [.text("\(webSwitchKeyPrefix).*"), .text(webSwitchOnValue)])
        var snapshot = AgenticWebSwitchSnapshot()
        for row in rows {
            let parts = try row.text("key").split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            // A key this build cannot read names a capability it cannot grant.
            switch (parts.count, parts.dropFirst().first) {
            case (3, "app"?):
                guard let capability = AgenticWebSwitchCapability(rawValue: parts[2]) else { continue }
                snapshot.app.insert(capability)
            case (4, "bot"?):
                guard let capability = AgenticWebSwitchCapability(rawValue: parts[3]),
                      let uuid = UUID(uuidString: parts[2]) else { continue }
                snapshot.bots[TeammateID(uuid), default: []].insert(capability)
            default:
                continue
            }
        }
        return snapshot
    }

    public func setAppWebSwitch(_ capability: AgenticWebSwitchCapability, enabled: Bool) async throws {
        try writeWebSwitch(key: "\(webSwitchKeyPrefix).app.\(capability.rawValue)", enabled: enabled)
    }

    public func setBotWebSwitch(_ capability: AgenticWebSwitchCapability, enabled: Bool, teammateID: TeammateID) async throws {
        try writeWebSwitch(key: "\(webSwitchKeyPrefix).bot.\(teammateID.persistedValue).\(capability.rawValue)", enabled: enabled)
    }

    private func writeWebSwitch(key: String, enabled: Bool) throws {
        try Task.checkCancellation()
        if enabled {
            _ = try execute(sql: """
                INSERT INTO app_metadata(key,value) VALUES (?,?)
                ON CONFLICT(key) DO UPDATE SET value=excluded.value;
                """, bindings: [.text(key), .text(webSwitchOnValue)])
        } else {
            _ = try execute(sql: "DELETE FROM app_metadata WHERE key=?;", bindings: [.text(key)])
        }
    }
}
