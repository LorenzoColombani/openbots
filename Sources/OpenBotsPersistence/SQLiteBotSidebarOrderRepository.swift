import OpenBotsDomain

extension SQLiteStore: BotSidebarOrderRepository {
    public func loadBotSidebarOrder() async throws -> BotSidebarOrder {
        try Task.checkCancellation()
        // One SQL statement reads both membership and revision from the same
        // SQLite snapshot, including when the roster is empty.
        return try botSidebarOrderSnapshot()
    }

    public func saveBotSidebarOrder(
        _ ids: [TeammateID], expectedRevision: UInt64
    ) async throws -> BotSidebarOrder {
        try Task.checkCancellation()
        return try transaction {
            try Task.checkCancellation()
            let current = try botSidebarOrderSnapshot()
            guard expectedRevision == current.revision else { throw BotSidebarOrderError.staleRevision }
            let activeIDs = try query(sql: "SELECT teammate_id FROM bot_sidebar_active_memberships;")
                .map { try parseID(TeammateID.self, $0.text("teammate_id")) }
            guard ids.count == Set(ids).count,
                  Set(ids) == Set(current.teammateIDs),
                  Set(ids) == Set(activeIDs) else {
                throw BotSidebarOrderError.invalidMembership
            }
            let saved = try writeBotSidebarOrder(ids, replacing: current)
            try Task.checkCancellation()
            return saved
        }
    }

    /// Called inside the new-bot aggregate transaction, after membership exists.
    /// Restore and ordinary membership changes retain their existing placement.
    func placeNewBotAtTopOfSidebarOrder(_ id: TeammateID) throws {
        let current = try botSidebarOrderSnapshot()
        guard current.teammateIDs.contains(id) else { return }
        _ = try writeBotSidebarOrder([id] + current.teammateIDs.filter { $0 != id }, replacing: current)
    }

    private func writeBotSidebarOrder(_ ids: [TeammateID], replacing current: BotSidebarOrder) throws -> BotSidebarOrder {
        // A boundary or cancelled-back-to-origin drag has no durable effect.
        guard ids != current.teammateIDs else { return current }
        guard current.revision < UInt64(Int64.max) else { throw BotSidebarOrderError.revisionExhausted }
        _ = try execute(sql: "DELETE FROM bot_sidebar_order;")
        for (position, id) in ids.enumerated() {
            _ = try execute(sql: "INSERT INTO bot_sidebar_order(teammate_id,position) VALUES (?,?);",
                            bindings: [.text(id.persistedValue), .integer(Int64(position))])
        }
        let changed = try execute(sql: """
            UPDATE bot_sidebar_order_state SET revision=revision+1
            WHERE singleton_id=1 AND revision=?;
            """, bindings: [.integer(Int64(current.revision))])
        guard changed == 1 else { throw BotSidebarOrderError.staleRevision }
        return BotSidebarOrder(teammateIDs: ids, revision: current.revision + 1)
    }

    private func botSidebarOrderSnapshot() throws -> BotSidebarOrder {
        let rows = try query(sql: """
            SELECT s.revision, o.teammate_id FROM bot_sidebar_order_state s
            LEFT JOIN bot_sidebar_order o ON 1=1
            WHERE s.singleton_id=1 ORDER BY o.position;
            """)
        guard let first = rows.first else {
            throw RepositoryError.unavailable(reason: "The bot sidebar order singleton is missing.")
        }
        let revision = try checkedUInt64(first.integer("revision"), field: "bot sidebar order revision")
        let ids = try rows.compactMap { row in
            try row.optionalText("teammate_id").map { try parseID(TeammateID.self, $0) }
        }
        return BotSidebarOrder(teammateIDs: ids, revision: revision)
    }
}
