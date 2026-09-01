import Foundation
import OpenBotsDomain
import OpenBotsServices

/// Persists navigation order without reloading conversations or replacing row
/// identities. Membership and selected-chat state remain owned by the workspace.
@MainActor
public final class WorkspaceSidebarOrderCoordinator {
    private let sidebar: SidebarModel
    private let service: any BotSidebarOrdering
    private let canReorder: @MainActor () -> Bool
    private var operation: Task<Void, Never>?
    private var isSaving = false
    private var isShuttingDown = false

    public init(sidebar: SidebarModel, service: any BotSidebarOrdering,
                canReorder: @escaping @MainActor () -> Bool) {
        self.sidebar = sidebar
        self.service = service
        self.canReorder = canReorder
        sidebar.configureOrderMoves { [weak self] ids, snapshot in
            guard let self, !self.isSaving, !self.isShuttingDown, self.canReorder() else { return }
            // Disable another drop synchronously, before the new task runs.
            self.sidebar.setOrderSaveState(isSaving: true, error: nil)
            self.operation = Task { @MainActor [weak self] in
                await self?.reorder(ids, fromSnapshot: snapshot)
            }
        }
    }

    public func reorder(_ ids: [UUID], fromSnapshot: [UUID]) async {
        guard !isSaving, !isShuttingDown else { return }
        guard canReorder() else {
            sidebar.setOrderSaveState(isSaving: false, error: nil)
            return
        }
        guard fromSnapshot == sidebar.rows.map(\.id), ids.count == Set(ids).count,
              Set(ids) == Set(fromSnapshot), ids != fromSnapshot else {
            sidebar.setOrderSaveState(isSaving: false, error: nil)
            return
        }
        isSaving = true
        sidebar.setOrderSaveState(isSaving: true, error: nil)
        var errorMessage: String?
        var didCommit = false
        defer {
            isSaving = false
            if !isShuttingDown { sidebar.setOrderSaveState(isSaving: false, error: errorMessage) }
        }
        do {
            let before = try await service.loadOrder()
            try Task.checkCancellation()
            guard !isShuttingDown, canReorder(), fromSnapshot == sidebar.rows.map(\.id),
                  before.teammateIDs.map(\.rawValue) == fromSnapshot else {
                throw BotSidebarOrderError.staleRevision
            }
            _ = try await service.saveOrder(ids.map(TeammateID.init), expectedRevision: before.revision)
            didCommit = true
            // Another lifecycle/order operation may commit while the save's
            // response is in flight. Publish the newest confirmed order only.
            let confirmed = try await service.loadOrder()
            try Task.checkCancellation()
            guard !isShuttingDown else { return }
            applyConfirmed(confirmed)
        } catch is CancellationError {
            errorMessage = "The order change was interrupted. Your saved chats and drafts are unchanged."
        } catch {
            if let orderingError = error as? BotSidebarOrderError,
               orderingError == .staleRevision || orderingError == .invalidMembership {
                // Refresh only positions of rows the workspace currently owns.
                // Never reload a conversation or remove a concurrent newcomer.
                if let latest = try? await service.loadOrder(), !isShuttingDown {
                    applyConfirmed(latest)
                }
                errorMessage = "The bot list changed. Its saved order is shown; drag the bot again."
            } else {
                errorMessage = didCommit
                    ? "The order was saved, but the list could not refresh. Reopen the workspace to see its saved order."
                    : "Couldn’t save the bot order. Your chats and drafts are unchanged. Try dragging again."
            }
        }
    }

    private func applyConfirmed(_ order: BotSidebarOrder) {
        let rows = sidebar.rows
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let known = order.teammateIDs.compactMap { byID[$0.rawValue] }
        let orderedIDs = Set(known.map(\.id))
        // Creation or restore may be presented after the read above. Preserve
        // those rows' current positions (new at top, restored at bottom) while
        // applying the confirmed relative order of the rows this read knows.
        var confirmed = known.makeIterator()
        sidebar.replace(rows: rows.map { row in
            orderedIDs.contains(row.id) ? (confirmed.next() ?? row) : row
        })
    }

    public func beginShutdown() {
        isShuttingDown = true
        operation?.cancel()
        sidebar.setOrderSaveState(isSaving: true, error: nil)
    }
}
