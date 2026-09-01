import OpenBotsDomain

public protocol BotSidebarOrdering: Sendable {
    func loadOrder() async throws -> BotSidebarOrder
    func saveOrder(_ ids: [TeammateID], expectedRevision: UInt64) async throws -> BotSidebarOrder
}

public actor BotSidebarOrderService: BotSidebarOrdering {
    private let repository: any BotSidebarOrderRepository

    public init(repository: any BotSidebarOrderRepository) {
        self.repository = repository
    }

    public func loadOrder() async throws -> BotSidebarOrder {
        try Task.checkCancellation()
        return try await repository.loadBotSidebarOrder()
    }

    public func saveOrder(_ ids: [TeammateID], expectedRevision: UInt64) async throws -> BotSidebarOrder {
        try Task.checkCancellation()
        return try await repository.saveBotSidebarOrder(ids, expectedRevision: expectedRevision)
    }
}
