import Combine
import Foundation

/// Small, screen-scoped presentation model for authoritative Markdown
/// reading and explicit one-shot snapshot publication.
///
/// Filesystem/database authority remains behind injected closures. Constructing
/// this model performs no I/O, retains no file URL, and grants no capability.
@MainActor
public final class KnowledgeWorkspaceModel: ObservableObject {
    public typealias Loader = @Sendable (
        _ context: KnowledgeWorkspaceContext
    ) async throws -> KnowledgeWorkspaceSnapshot
    public typealias Revealer = @Sendable (
        _ workspaceSnapshotID: UUID,
        _ documentID: UUID
    ) async throws -> Void
    public typealias SnapshotDestinationChooser = @MainActor @Sendable (
        _ workspaceSnapshotID: UUID
    ) async throws -> KnowledgeSnapshotDestination?
    public typealias SnapshotCreator = @Sendable (
        _ workspaceSnapshotID: UUID,
        _ destination: KnowledgeSnapshotDestination
    ) async throws -> KnowledgeSnapshotReceipt
    public typealias SnapshotDestinationReleaser = @Sendable (
        _ destination: KnowledgeSnapshotDestination
    ) async -> Void

    public static let loadFailureMessage =
        "OpenBots couldn’t load the verified local knowledge for this context."
    public static let revealFailureMessage =
        "OpenBots couldn’t reveal this verified Markdown revision."
    public static let destinationFailureMessage =
        "OpenBots couldn’t prepare that exact snapshot destination. No file was created."
    public static let creationFailureMessage =
        "OpenBots couldn’t create the snapshot. No existing item was replaced."
    public static let noContextMessage =
        "Choose a teammate conversation to review its scoped knowledge."

    @Published public private(set) var context: KnowledgeWorkspaceContext?
    @Published public private(set) var loadState: KnowledgeWorkspaceLoadState = .idle
    @Published public private(set) var revealingDocumentID: UUID?
    @Published public private(set) var revealFailure: String?
    @Published public private(set) var isChoosingSnapshotDestination = false
    @Published public private(set) var pendingSnapshot: PendingKnowledgeSnapshot?
    @Published public private(set) var isCreatingSnapshot = false
    @Published public private(set) var snapshotFailure: String?
    @Published public private(set) var snapshotReceipt: KnowledgeSnapshotReceipt?

    private let loader: Loader
    private let revealer: Revealer
    private let chooseSnapshotDestination: SnapshotDestinationChooser
    private let createSnapshot: SnapshotCreator
    private let releaseSnapshotDestination: SnapshotDestinationReleaser
    private var generation: UInt64 = 0

    public init(
        loader: @escaping Loader,
        revealer: @escaping Revealer,
        chooseSnapshotDestination: @escaping SnapshotDestinationChooser,
        createSnapshot: @escaping SnapshotCreator,
        releaseSnapshotDestination: @escaping SnapshotDestinationReleaser
    ) {
        self.loader = loader
        self.revealer = revealer
        self.chooseSnapshotDestination = chooseSnapshotDestination
        self.createSnapshot = createSnapshot
        self.releaseSnapshotDestination = releaseSnapshotDestination
    }

    public var snapshot: KnowledgeWorkspaceSnapshot? {
        guard case .ready(let snapshot) = loadState else { return nil }
        return snapshot
    }

    public var canChooseSnapshotDestination: Bool {
        guard let snapshot, !snapshot.documents.isEmpty else { return false }
        return !isChoosingSnapshotDestination
            && !isCreatingSnapshot
            && pendingSnapshot == nil
    }

    /// Replaces the exact conversation/work context and synchronously clears
    /// content and pending confirmations from the previous context. Any async
    /// result already in flight is rejected by its generation on return.
    public func activateContext(_ context: KnowledgeWorkspaceContext?) {
        guard self.context != context else { return }
        generation &+= 1
        let abandonedDestination = pendingSnapshot?.destination
        self.context = context
        loadState = context == nil ? .unavailable(reason: Self.noContextMessage) : .idle
        revealingDocumentID = nil
        revealFailure = nil
        isChoosingSnapshotDestination = false
        pendingSnapshot = nil
        isCreatingSnapshot = false
        snapshotFailure = nil
        snapshotReceipt = nil

        if let abandonedDestination {
            let releaseSnapshotDestination = self.releaseSnapshotDestination
            Task {
                await releaseSnapshotDestination(abandonedDestination)
            }
        }
    }

    public func load() async {
        guard let context else {
            loadState = .unavailable(reason: Self.noContextMessage)
            return
        }
        guard loadState != .loading, !isCreatingSnapshot else { return }

        generation &+= 1
        let requestedGeneration = generation
        let loader = self.loader
        let abandonedDestination = pendingSnapshot?.destination
        loadState = .loading
        revealFailure = nil
        isChoosingSnapshotDestination = false
        pendingSnapshot = nil
        snapshotFailure = nil
        snapshotReceipt = nil

        if let abandonedDestination {
            await releaseSnapshotDestination(abandonedDestination)
            guard requestedGeneration == generation, self.context == context else { return }
        }

        do {
            let loaded = try await loader(context)
            guard requestedGeneration == generation, self.context == context else { return }
            guard Self.isValid(loaded, for: context) else {
                loadState = .failed(reason: Self.loadFailureMessage)
                return
            }
            loadState = .ready(loaded)
        } catch {
            guard requestedGeneration == generation, self.context == context else { return }
            loadState = .failed(reason: Self.loadFailureMessage)
        }
    }

    public func revealInFinder(documentID: UUID) async {
        guard revealingDocumentID == nil,
              let snapshot,
              let document = snapshot.documents.first(where: { $0.id == documentID }),
              document.canRevealInFinder else {
            return
        }
        let requestedGeneration = generation
        let requestedSnapshotID = snapshot.id
        let revealer = self.revealer
        revealingDocumentID = documentID
        revealFailure = nil

        do {
            try await revealer(requestedSnapshotID, documentID)
        } catch {
            guard requestedGeneration == generation, self.snapshot?.id == requestedSnapshotID else {
                return
            }
            revealFailure = Self.revealFailureMessage
        }

        guard requestedGeneration == generation, self.snapshot?.id == requestedSnapshotID else {
            return
        }
        revealingDocumentID = nil
    }

    /// Runs the injected native save-panel/capability boundary. A successful
    /// choice produces only an inline confirmation target; it never invokes
    /// the writer.
    public func selectSnapshotDestination() async {
        guard canChooseSnapshotDestination, let snapshot else { return }
        let requestedGeneration = generation
        let requestedSnapshotID = snapshot.id
        let chooser = chooseSnapshotDestination
        let releaser = releaseSnapshotDestination
        isChoosingSnapshotDestination = true
        snapshotFailure = nil
        snapshotReceipt = nil

        do {
            let destination = try await chooser(requestedSnapshotID)
            guard requestedGeneration == generation, self.snapshot?.id == requestedSnapshotID else {
                if let destination { await releaser(destination) }
                return
            }
            isChoosingSnapshotDestination = false
            guard let destination else { return }
            guard Self.isValid(destination) else {
                await releaser(destination)
                snapshotFailure = Self.destinationFailureMessage
                return
            }
            pendingSnapshot = PendingKnowledgeSnapshot(
                workspaceSnapshotID: requestedSnapshotID,
                destination: destination
            )
        } catch {
            guard requestedGeneration == generation, self.snapshot?.id == requestedSnapshotID else {
                return
            }
            isChoosingSnapshotDestination = false
            snapshotFailure = Self.destinationFailureMessage
        }
    }

    public func cancelPendingSnapshot() async {
        guard !isCreatingSnapshot, let pendingSnapshot else { return }
        self.pendingSnapshot = nil
        let releaser = releaseSnapshotDestination
        await releaser(pendingSnapshot.destination)
    }

    /// The sole UI path that invokes the external create-new writer. The
    /// destination is consumed once; failure requires a fresh picker choice.
    public func confirmSnapshotCreation() async {
        guard !isCreatingSnapshot,
              let pendingSnapshot,
              let snapshot,
              pendingSnapshot.workspaceSnapshotID == snapshot.id else {
            return
        }
        let requestedGeneration = generation
        let requestedSnapshotID = snapshot.id
        let destination = pendingSnapshot.destination
        let expectedDocumentCount = snapshot.documents.count
        let creator = createSnapshot
        let releaser = releaseSnapshotDestination
        self.pendingSnapshot = nil
        isCreatingSnapshot = true
        snapshotFailure = nil
        snapshotReceipt = nil

        do {
            let receipt = try await creator(requestedSnapshotID, destination)
            await releaser(destination)
            guard requestedGeneration == generation, self.snapshot?.id == requestedSnapshotID else {
                return
            }
            guard receipt.exactDisplayPath == destination.exactDisplayPath,
                  receipt.documentCount == expectedDocumentCount else {
                snapshotFailure = Self.creationFailureMessage
                isCreatingSnapshot = false
                return
            }
            snapshotReceipt = receipt
        } catch {
            await releaser(destination)
            guard requestedGeneration == generation, self.snapshot?.id == requestedSnapshotID else {
                return
            }
            snapshotFailure = Self.creationFailureMessage
        }

        guard requestedGeneration == generation, self.snapshot?.id == requestedSnapshotID else {
            return
        }
        isCreatingSnapshot = false
    }

    private static func isValid(
        _ snapshot: KnowledgeWorkspaceSnapshot,
        for context: KnowledgeWorkspaceContext
    ) -> Bool {
        guard snapshot.context == context,
              Set(snapshot.documents.map(\.id)).count == snapshot.documents.count else {
            return false
        }

        return snapshot.documents.allSatisfy { document in
            guard document.revision > 0 else { return false }
            switch document.scope {
            case .user:
                return true
            case .teammate(let id, _):
                return id == context.teammateID
            case .project(let id, _):
                return id == context.selectedProjectID
                    && context.activeProjectMembershipIDs.contains(id)
            }
        }
    }

    private static func isValid(_ destination: KnowledgeSnapshotDestination) -> Bool {
        let path = destination.exactDisplayPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !path.isEmpty && NSString(string: path).isAbsolutePath
    }
}
