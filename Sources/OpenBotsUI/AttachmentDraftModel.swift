import Combine
import Foundation
import OpenBotsDomain

/// A path-free summary returned by the attachment ingestion boundary.
///
/// Legacy receipts are preview-only. An optional immutable asset identifies a
/// saved draft copy, never a sent message or published workspace artifact.
public struct AttachmentDraftPresentationReceipt: Equatable, Sendable {
    public static let draftOnlyDisclosure =
        "Draft preview only. This file is not yet attached, published, or saved to the conversation."

    public let displayName: String
    public let byteCount: UInt64
    public let shortHash: String
    public let asset: AttachmentAsset?
    public var isDurable: Bool { asset != nil }
    public var disclosure: String {
        isDurable ? "Saved with this conversation’s draft. It will be attached when you send." : Self.draftOnlyDisclosure
    }

    public init(displayName: String, byteCount: UInt64, shortHash: String, asset: AttachmentAsset? = nil) {
        self.displayName = Self.safeDisplayName(displayName)
        self.byteCount = byteCount
        self.shortHash = Self.safeShortHash(shortHash)
        self.asset = asset
    }

    public init(asset: AttachmentAsset) {
        self.init(displayName: asset.displayName, byteCount: UInt64(clamping: asset.byteCount),
                  shortHash: String(asset.sha256.prefix(12)), asset: asset)
    }

    private static func safeDisplayName(_ candidate: String) -> String {
        let withoutControls = candidate
            .components(separatedBy: .controlCharacters)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pathLeaf = URL(fileURLWithPath: withoutControls).lastPathComponent
        let leaf = pathLeaf.split(separator: "\\", omittingEmptySubsequences: true).last.map(String.init)
            ?? pathLeaf
        let bounded = String(leaf.prefix(180))
        return bounded.isEmpty ? "Attachment" : bounded
    }

    private static func safeShortHash(_ candidate: String) -> String {
        let allowed = candidate.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }
        return String(String.UnicodeScalarView(allowed).prefix(16)).lowercased()
    }
}

public enum AttachmentDraftRowState: Equatable, Sendable {
    case pending
    case ready(AttachmentDraftPresentationReceipt)
    case failed(String)
}

public struct AttachmentDraftRow: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let selectedDisplayName: String
    public let state: AttachmentDraftRowState
    public let isRemoving: Bool

    public init(id: UUID, selectedDisplayName: String, state: AttachmentDraftRowState, isRemoving: Bool = false) {
        self.id = id
        self.selectedDisplayName = selectedDisplayName
        self.state = state
        self.isRemoving = isRemoving
    }

    public var accessibilityDescription: String {
        if isRemoving { return "Removing \(selectedDisplayName) from this draft. The original file is unchanged." }
        switch state {
        case .pending:
            return "\(selectedDisplayName). Preparing a local attachment."
        case .ready(let receipt):
            return "\(receipt.displayName). \(receipt.byteCount) bytes. \(receipt.disclosure)"
        case .failed(let message):
            return "\(selectedDisplayName). \(message)"
        }
    }

    fileprivate func replacingState(_ state: AttachmentDraftRowState) -> Self {
        Self(id: id, selectedDisplayName: selectedDisplayName, state: state, isRemoving: isRemoving)
    }

    fileprivate func replacingRemoval(_ value: Bool) -> Self {
        Self(id: id, selectedDisplayName: selectedDisplayName, state: state, isRemoving: value)
    }
}

public enum AttachmentDraftLoadState: Equatable, Sendable {
    case notLoaded, loading, ready, failed(String)
}

public enum AttachmentDraftSubmissionError: Error, Equatable, Sendable {
    case unresolvedDraft
    case previewOnly
}

/// Conversation-scoped attachment draft presentation state.
///
/// Selection immediately creates a pending row. The injected importer receives
/// the exact selected URL and operation ID under one-shot security-scoped
/// access, then updates that same row identity with a path-free result. This
/// model retains no source paths or bookmarks. Its optional durable adapter
/// owns registration and exact draft-link removal, not the presentation layer.
@MainActor
public final class AttachmentDraftModel: ObservableObject {
    public typealias Importer = @Sendable (
        _ exactURL: URL,
        _ operationID: UUID
    ) async throws -> AttachmentDraftPresentationReceipt
    public typealias Loader = @Sendable () async throws -> AttachmentDraftSnapshot
    public typealias DurableImporter = @Sendable (URL, UUID) async throws -> AttachmentAsset
    public typealias Remover = @Sendable (AttachmentID) async throws -> AttachmentDraftSnapshot

    public static let maximumPendingRows = 4
    public static let maximumPresentationRows = 24
    public static let importFailureMessage =
        "OpenBots couldn’t prepare this attachment. The source file was not changed."
    public static let removalFailureMessage =
        "OpenBots couldn’t remove this file from the draft. Try Remove again. The original file was not changed."

    @Published public private(set) var rows: [AttachmentDraftRow] = []
    @Published public private(set) var loadState: AttachmentDraftLoadState
    @Published public private(set) var isShuttingDown = false

    private let importer: Importer?
    private let conversationID: ConversationID?
    private let loader: Loader?
    private let durableImporter: DurableImporter?
    private let remover: Remover?
    private var activeOperationIDs: Set<UUID> = []
    private var consumedOperationIDs: Set<UUID> = []
    private var importTasks: [UUID: Task<Void, Never>] = [:]
    private var removalTasks: [UUID: Task<Void, Never>] = [:]
    private var cancelledImports: Set<UUID> = []
    private var assetsByRow: [UUID: AttachmentAsset] = [:]
    private var removalTargets: [UUID: AttachmentID] = [:]
    private var shutdownFinished = false
    private var shutdownWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    public init(importer: @escaping Importer) {
        self.importer = importer
        conversationID = nil
        loader = nil
        durableImporter = nil
        remover = nil
        loadState = .ready
    }

    /// Bound to one exact conversation. Construction does not read or create
    /// anything; the caller explicitly loads before accepting selections.
    public init(conversationID: ConversationID, load: @escaping Loader,
                importFile: @escaping DurableImporter, remove: @escaping Remover) {
        self.conversationID = conversationID
        importer = nil
        loader = load
        durableImporter = importFile
        remover = remove
        loadState = .notLoaded
    }

    public var isDurable: Bool { conversationID != nil }
    public var hasDurableAttachments: Bool { !assetsByRow.isEmpty }
    public var canSubmit: Bool {
        !isShuttingDown && loadState == .ready && activeOperationIDs.isEmpty && removalTasks.isEmpty
            && rows.allSatisfy { row in
                guard !row.isRemoving, case .ready(let receipt) = row.state else { return false }
                return receipt.isDurable
            }
    }
    public var disclosure: String {
        isDurable ? "Attachments are saved with this draft. Remove only changes the draft, never the original file."
            : AttachmentDraftPresentationReceipt.draftOnlyDisclosure
    }

    public func load() async {
        guard !isShuttingDown, loadState == .notLoaded else { return }
        await reload()
    }

    public func reload() async {
        guard !isShuttingDown, let loader, loadState != .loading, importTasks.isEmpty, removalTasks.isEmpty else { return }
        loadState = .loading
        do {
            let snapshot = try await loader()
            guard !isShuttingDown else { return }
            try validate(snapshot)
            var restored: [AttachmentDraftRow] = []
            var restoredAssets: [UUID: AttachmentAsset] = [:]
            for asset in snapshot.attachments {
                let rowID = assetsByRow.first(where: { $0.value.id == asset.id })?.key ?? asset.id.rawValue
                restored.append(AttachmentDraftRow(id: rowID, selectedDisplayName: asset.displayName,
                                                    state: .ready(AttachmentDraftPresentationReceipt(asset: asset))))
                restoredAssets[rowID] = asset
                consumedOperationIDs.insert(rowID)
            }
            rows = restored
            assetsByRow = restoredAssets
            removalTargets = [:]
            cancelledImports = []
            loadState = .ready
        } catch {
            guard !isShuttingDown else { return }
            loadState = .failed("OpenBots couldn’t load this conversation’s attachment draft. Try Reload. Your files were not changed.")
        }
    }

    /// A synchronous immutable send capture. It never clears the draft; only
    /// a confirmed durable message write permits acknowledgeSubmitted.
    public func freezeForSubmission() throws -> [AttachmentAsset] {
        guard !isShuttingDown, loadState == .ready, activeOperationIDs.isEmpty, removalTasks.isEmpty,
              !rows.contains(where: { $0.isRemoving }) else { throw AttachmentDraftSubmissionError.unresolvedDraft }
        return try rows.map { row in
            guard case .ready(let receipt) = row.state else { throw AttachmentDraftSubmissionError.unresolvedDraft }
            guard let asset = receipt.asset, asset.conversationID == conversationID else {
                throw AttachmentDraftSubmissionError.previewOnly
            }
            return asset
        }
    }

    public func acknowledgeSubmitted(ids: Set<AttachmentID>) {
        guard !shutdownFinished else { return }
        let capturedRows = Set(assetsByRow.filter { ids.contains($0.value.id) }.map(\.key))
        rows.removeAll { capturedRows.contains($0.id) }
        for id in capturedRows {
            assetsByRow.removeValue(forKey: id)
            removalTargets.removeValue(forKey: id)
        }
        resolveShutdownWaitersIfSettled()
    }

    /// Starts one exact-file import and returns whether it was accepted.
    /// Invalid/non-file URLs, reused operation IDs, and requests beyond the
    /// bounded pending/row limits are rejected before the importer is invoked.
    @discardableResult
    public func selectFile(
        at exactURL: URL,
        operationID: UUID = UUID()
    ) -> Bool {
        guard !isShuttingDown, let displayName = Self.validDisplayName(for: exactURL),
              loadState == .ready,
              !consumedOperationIDs.contains(operationID),
              activeOperationIDs.count < Self.maximumPendingRows,
              rows.count < Self.maximumPresentationRows else {
            return false
        }

        consumedOperationIDs.insert(operationID)
        activeOperationIDs.insert(operationID)
        if isDurable { removalTargets[operationID] = AttachmentID(operationID) }
        rows.append(
            AttachmentDraftRow(
                id: operationID,
                selectedDisplayName: displayName,
                state: .pending
            )
        )

        importTasks[operationID] = Task { @MainActor [weak self] in
            guard let self else { return }
            // A selection admitted just before close may not have started yet.
            // Do not open its security scope or begin a new read after freeze.
            guard !isShuttingDown else {
                finishImport(operationID: operationID, state: .failed(Self.importFailureMessage))
                return
            }
            let didStartSecurityScope = exactURL.startAccessingSecurityScopedResource()
            defer {
                if didStartSecurityScope {
                    exactURL.stopAccessingSecurityScopedResource()
                }
            }

            do {
                try Task.checkCancellation()
                let receipt: AttachmentDraftPresentationReceipt
                if let durableImporter {
                    let asset = try await durableImporter(exactURL, operationID)
                    guard !shutdownFinished else { return }
                    guard asset.conversationID == conversationID, asset.id.rawValue == operationID else {
                        throw AttachmentDraftSubmissionError.unresolvedDraft
                    }
                    assetsByRow[operationID] = asset
                    receipt = AttachmentDraftPresentationReceipt(asset: asset)
                } else if let importer {
                    receipt = try await importer(exactURL, operationID)
                } else { throw AttachmentDraftSubmissionError.unresolvedDraft }
                finishImport(operationID: operationID, state: .ready(receipt))
            } catch {
                // Importer failures can contain source paths, provider details,
                // or other private diagnostics. The draft UI gets one stable,
                // path-free recovery message instead.
                finishImport(
                    operationID: operationID,
                    state: .failed(Self.importFailureMessage)
                )
            }
        }

        return true
    }

    /// Removes the exact draft link only, never original or immutable content.
    /// A cancelled import remains visible until its possible durable link is
    /// removed; late completion cannot silently bring it back into the draft.
    public func removePresentationRow(id: UUID) {
        guard !isShuttingDown, loadState != .loading, let row = rows.first(where: { $0.id == id }), !row.isRemoving else { return }
        guard isDurable else {
            importTasks[id]?.cancel()
            rows.removeAll { $0.id == id }
            return
        }
        if importTasks[id] != nil {
            cancelledImports.insert(id)
            removalTargets[id] = AttachmentID(id)
            setRemoving(id, true)
            importTasks[id]?.cancel()
        } else if let target = removalTargets[id] ?? assetsByRow[id]?.id {
            startRemoval(rowID: id, target: target)
        } else {
            rows.removeAll { $0.id == id }
        }
    }

    private func finishImport(operationID: UUID, state: AttachmentDraftRowState) {
        guard !shutdownFinished else { return }
        activeOperationIDs.remove(operationID)
        importTasks.removeValue(forKey: operationID)
        if cancelledImports.contains(operationID), isDurable, !isShuttingDown {
            // The adapter contract uses operationID as the immutable asset ID.
            // Remove is idempotent even if cancellation preceded registration.
            startRemoval(rowID: operationID, target: AttachmentID(operationID))
        } else if let index = rows.firstIndex(where: { $0.id == operationID }) {
            rows[index] = rows[index].replacingState(state)
        }
        resolveShutdownWaitersIfSettled()
    }

    private func startRemoval(rowID: UUID, target: AttachmentID) {
        guard !isShuttingDown, let remover, removalTasks[rowID] == nil, rows.contains(where: { $0.id == rowID }) else { return }
        removalTargets[rowID] = target
        setRemoving(rowID, true)
        // This independent task is not cancelled with the import whose exact
        // link it reconciles. It has no original-file or blob-delete closure.
        removalTasks[rowID] = Task { @MainActor [weak self] in
            guard let self else { return }
            guard !isShuttingDown else {
                removalTasks.removeValue(forKey: rowID)
                resolveShutdownWaitersIfSettled()
                return
            }
            do {
                let snapshot = try await remover(target)
                guard !shutdownFinished else { return }
                try validate(snapshot)
                guard !snapshot.attachments.contains(where: { $0.id == target }) else {
                    throw AttachmentDraftSubmissionError.unresolvedDraft
                }
                rows.removeAll { $0.id == rowID }
                assetsByRow.removeValue(forKey: rowID)
                removalTargets.removeValue(forKey: rowID)
                cancelledImports.remove(rowID)
            } catch {
                guard !shutdownFinished else { return }
                if let index = rows.firstIndex(where: { $0.id == rowID }) {
                    rows[index] = rows[index].replacingState(.failed(Self.removalFailureMessage)).replacingRemoval(false)
                }
            }
            removalTasks.removeValue(forKey: rowID)
            resolveShutdownWaitersIfSettled()
        }
    }

    /// Closes admission synchronously. Only imports/removals whose injected
    /// operation has already started may settle during the app's one grace.
    public func beginShutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
    }

    /// Waits for existing work, never starts a save, retry or cleanup. The app
    /// owns the deadline and must call finishShutdown even for a stuck adapter.
    public func settleForShutdown() async -> Bool {
        guard isShuttingDown, !shutdownFinished, !Task.isCancelled else { return false }
        if importTasks.isEmpty && removalTasks.isEmpty { return settledSuccessfully }
        let id = UUID()
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                shutdownWaiters[id] = continuation
                resolveShutdownWaitersIfSettled()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.shutdownWaiters.removeValue(forKey: id)?.resume(returning: false)
            }
        }
        return result && !shutdownFinished && !Task.isCancelled
    }

    /// Terminal fence, not proof that cancellation stops arbitrary adapter
    /// code. A late durable commit stays on disk for reopen; it cannot publish
    /// UI state or start compensating removal after this boundary.
    public func finishShutdown() {
        beginShutdown()
        guard !shutdownFinished else { return }
        shutdownFinished = true
        for task in importTasks.values { task.cancel() }
        for task in removalTasks.values { task.cancel() }
        importTasks.removeAll()
        removalTasks.removeAll()
        activeOperationIDs.removeAll()
        let waiters = shutdownWaiters.values
        shutdownWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: false) }
    }

    private var settledSuccessfully: Bool {
        loadState == .ready && rows.allSatisfy { row in
            guard !row.isRemoving, case .ready(let receipt) = row.state else { return false }
            return receipt.isDurable
        }
    }

    private func resolveShutdownWaitersIfSettled() {
        guard isShuttingDown, !shutdownFinished, importTasks.isEmpty, removalTasks.isEmpty else { return }
        let result = settledSuccessfully
        let waiters = shutdownWaiters.values
        shutdownWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: result) }
    }

    private func setRemoving(_ id: UUID, _ value: Bool) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index] = rows[index].replacingRemoval(value)
    }

    private func validate(_ snapshot: AttachmentDraftSnapshot) throws {
        guard snapshot.conversationID == conversationID, snapshot.revision >= 0,
              snapshot.revision > 0 || snapshot.attachments.isEmpty,
              snapshot.attachments.count <= Self.maximumPresentationRows,
              Set(snapshot.attachments.map(\.id)).count == snapshot.attachments.count,
              snapshot.attachments.allSatisfy({ $0.conversationID == conversationID }) else {
            throw AttachmentDraftSubmissionError.unresolvedDraft
        }
    }

    private static func validDisplayName(for exactURL: URL) -> String? {
        guard exactURL.isFileURL, exactURL.path.hasPrefix("/") else { return nil }
        let candidate = exactURL.lastPathComponent
            .components(separatedBy: .controlCharacters)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, candidate != ".", candidate != ".." else {
            return nil
        }
        return String(candidate.prefix(180))
    }
}
