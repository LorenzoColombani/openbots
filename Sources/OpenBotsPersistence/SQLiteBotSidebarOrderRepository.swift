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
            // A hidden bot is a member the list does not show: a drag names only
            // the shown ones, and the hidden keep their slots (writeBotSidebarOrder).
            let hiddenIDs = try teammateIDs(where: "is_hidden=1")
            guard ids.count == Set(ids).count,
                  Set(ids) == Set(current.teammateIDs),
                  Set(ids) == Set(activeIDs).subtracting(hiddenIDs) else {
                throw BotSidebarOrderError.invalidMembership
            }
            let saved = try writeBotSidebarOrder(ids, replacing: current)
            try Task.checkCancellation()
            return saved
        }
    }

    /// Called inside the new-bot aggregate transaction, after membership exists.
    /// Restore and ordinary membership changes retain their existing placement.
    /// A new bot is unpinned, so it lands first below the pinned bots.
    func placeNewBotAtTopOfSidebarOrder(_ id: TeammateID) throws {
        let current = try botSidebarOrderSnapshot()
        guard current.teammateIDs.contains(id) else { return }
        _ = try writeBotSidebarOrder([id] + current.teammateIDs.filter { $0 != id }, replacing: current)
    }

    private func writeBotSidebarOrder(_ requested: [TeammateID], replacing current: BotSidebarOrder) throws -> BotSidebarOrder {
        let stored = try query(sql: "SELECT teammate_id FROM bot_sidebar_order ORDER BY position;")
            .map { try parseID(TeammateID.self, $0.text("teammate_id")) }
        // A stored member the request does not name is a hidden bot: it goes back
        // into the slot it held, so unhiding it later shows it where it was.
        var complete = requested
        for (slot, id) in stored.enumerated() where !requested.contains(id) {
            complete.insert(id, at: min(slot, complete.count))
        }
        // Pinned bots are stored first, each group in the order asked for: a bot
        // dropped above a pinned one lands just below the pins.
        let pinned = try teammateIDs(where: "is_pinned=1")
        let ids = complete.filter { pinned.contains($0) } + complete.filter { !pinned.contains($0) }
        // A boundary or cancelled-back-to-origin drag has no durable effect. The
        // comparison is with the positions as stored, not as read: an order saved
        // before pins read first can hold a pinned bot below an unpinned one, which
        // reads the same today and would surface the moment another bot is pinned.
        guard ids != stored else { return current }
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
        return try botSidebarOrderSnapshot()
    }

    private func teammateIDs(where condition: String) throws -> Set<TeammateID> {
        Set(try query(sql: "SELECT id FROM teammates WHERE \(condition);")
            .map { try parseID(TeammateID.self, $0.text("id")) })
    }

    /// The order the sidebar shows: pinned bots first, then the rest, each group in
    /// its saved positions, and no hidden bot, since the list shows none. Pinning and unpinning write no
    /// positions: the flag alone moves a bot between the groups, and an unpinned bot
    /// goes back to its saved slot, the top of the rest if the order was saved while
    /// it was pinned. A restored bot appended at the bottom by the membership
    /// triggers reads at the end of its group.
    private func botSidebarOrderSnapshot() throws -> BotSidebarOrder {
        let rows = try query(sql: """
            SELECT s.revision, o.teammate_id FROM bot_sidebar_order_state s
            LEFT JOIN (
                SELECT o.teammate_id, o.position, t.is_pinned FROM bot_sidebar_order o
                JOIN teammates t ON t.id=o.teammate_id WHERE t.is_hidden=0
            ) o ON 1=1
            WHERE s.singleton_id=1 ORDER BY o.is_pinned DESC, o.position;
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
