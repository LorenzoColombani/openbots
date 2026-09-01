import Foundation
import OpenBotsContent
import OpenBotsDomain

public struct KnowledgeSnapshotDeliveryToken: Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID) {
        self.rawValue = rawValue
    }
}

/// Path-and-token receipt for one exact create-new action. It contains no
/// filesystem authority itself; the broker retains the frozen capability.
public struct FrozenKnowledgeSnapshotDelivery: Identifiable, Equatable, Sendable {
    public var id: KnowledgeSnapshotDeliveryToken { token }

    public let token: KnowledgeSnapshotDeliveryToken
    public let exactDisplayPath: String

    public init(token: KnowledgeSnapshotDeliveryToken, exactDisplayPath: String) {
        self.token = token
        self.exactDisplayPath = exactDisplayPath
    }
}

public struct KnowledgeSnapshotDeliveryReceipt: Equatable, Sendable {
    public static let nonAuthoritativeDisclosure =
        "Snapshot created as a non-authoritative copy. Edits there do not flow back to OpenBots."

    public let token: KnowledgeSnapshotDeliveryToken
    public let capabilityID: CapabilityGrantID
    public let exactDisplayPath: String
    public let byteCount: Int
    public let contentDigest: String
    public let documentCount: Int
    public let snapshotGeneratedAt: Date
    public let claimReferences: [MemoryClaimReference]
    public let policyVersion: UInt16
    public let disclosure: String

    fileprivate init(
        token: KnowledgeSnapshotDeliveryToken,
        capabilityID: CapabilityGrantID,
        exactDisplayPath: String,
        byteCount: Int,
        contentDigest: String,
        documentCount: Int,
        snapshotGeneratedAt: Date,
        claimReferences: [MemoryClaimReference]
    ) {
        self.token = token
        self.capabilityID = capabilityID
        self.exactDisplayPath = exactDisplayPath
        self.byteCount = byteCount
        self.contentDigest = contentDigest
        self.documentCount = documentCount
        self.snapshotGeneratedAt = snapshotGeneratedAt
        self.claimReferences = claimReferences
        policyVersion = MemoryClaimUsePolicy.version
        disclosure = Self.nonAuthoritativeDisclosure
    }
}

public enum KnowledgeSnapshotDeliveryError: Error, Equatable, Sendable {
    case staleOrUnknownToken
    case workspaceMismatch
    case targetMismatch
    case sharingDenied
}

/// Trusted host boundary, never a provider-decoded permission. Validation binds
/// the exact frozen payload, fresh current sources and create-new destination.
public protocol KnowledgeSnapshotSharingValidating: Sendable {
    func validate(snapshot: NonAuthoritativeKnowledgeSnapshot, workspaceSnapshotID: UUID,
                  capabilityID: CapabilityGrantID, exactTarget: URL) async throws
}

/// Holds completed snapshot bytes behind a one-shot exact-path capability.
/// Destination selection remains an App/UI responsibility; this actor never
/// opens a panel and never receives broader folder authority.
public actor KnowledgeSnapshotDeliveryBroker {
    private struct Pending: Sendable {
        let workspaceSnapshotID: UUID
        let snapshot: NonAuthoritativeKnowledgeSnapshot
        let plan: ExternalCreateNewPlan
    }

    private let locationChecker: any LocationEnvironmentChecking
    private let sharing: (any KnowledgeSnapshotSharingValidating)?
    private var pendingByToken: [KnowledgeSnapshotDeliveryToken: Pending] = [:]

    public init(
        locationChecker: any LocationEnvironmentChecking = FoundationLocationEnvironmentChecker(),
        sharing: (any KnowledgeSnapshotSharingValidating)? = nil
    ) {
        self.locationChecker = locationChecker
        self.sharing = sharing
    }

    /// Freezes the exact rendered bytes and exact final path without writing.
    /// The capability conveys create-new only: no overwrite, cleanup, rename,
    /// move, metadata mutation, or deletion authority is introduced.
    public func freeze(
        workspaceSnapshotID: UUID,
        snapshot: NonAuthoritativeKnowledgeSnapshot,
        exactTarget: URL
    ) async throws -> FrozenKnowledgeSnapshotDelivery {
        guard snapshot.purpose == .qualifiedSharing, let sharing else { throw KnowledgeSnapshotDeliveryError.sharingDenied }
        let capability = try ExternalCreateNewCapability.grant(
            id: CapabilityGrantID(UUID()),
            holder: .application,
            exactSelectedTarget: exactTarget,
            expectedByteCount: snapshot.data.count,
            locationChecker: locationChecker
        )
        try await sharing.validate(snapshot: snapshot, workspaceSnapshotID: workspaceSnapshotID,
            capabilityID: capability.id, exactTarget: capability.exactTarget)
        let token = uniqueToken()
        pendingByToken[token] = Pending(
            workspaceSnapshotID: workspaceSnapshotID,
            snapshot: snapshot,
            plan: ExternalCreateNewPlan(capability: capability)
        )
        return FrozenKnowledgeSnapshotDelivery(
            token: token,
            exactDisplayPath: capability.exactTarget.path
        )
    }

    /// Consumes the frozen action before I/O, so it cannot be replayed even if
    /// the exclusive write fails or finds a collision.
    public func create(
        workspaceSnapshotID: UUID,
        delivery: FrozenKnowledgeSnapshotDelivery
    ) async throws -> KnowledgeSnapshotDeliveryReceipt {
        guard let pending = pendingByToken[delivery.token] else {
            throw KnowledgeSnapshotDeliveryError.staleOrUnknownToken
        }
        guard pending.workspaceSnapshotID == workspaceSnapshotID else {
            throw KnowledgeSnapshotDeliveryError.workspaceMismatch
        }
        guard pending.plan.exactTarget.path == delivery.exactDisplayPath else {
            throw KnowledgeSnapshotDeliveryError.targetMismatch
        }
        pendingByToken.removeValue(forKey: delivery.token)
        guard pending.snapshot.purpose == .qualifiedSharing, let sharing else { throw KnowledgeSnapshotDeliveryError.sharingDenied }
        try Task.checkCancellation()
        try await sharing.validate(snapshot: pending.snapshot, workspaceSnapshotID: workspaceSnapshotID,
            capabilityID: pending.plan.capabilityID, exactTarget: pending.plan.exactTarget)
        try Task.checkCancellation()

        let writer = ExternalCreateNewWriter(locationChecker: locationChecker)
        let externalReceipt = try await Task.detached(priority: .utility) {
            try writer.write(pending.snapshot.data, using: pending.plan)
        }.value
        return KnowledgeSnapshotDeliveryReceipt(
            token: delivery.token,
            capabilityID: externalReceipt.capabilityID,
            exactDisplayPath: externalReceipt.exactTarget.path,
            byteCount: externalReceipt.byteCount,
            contentDigest: pending.snapshot.contentDigest,
            documentCount: pending.snapshot.sourceCount,
            snapshotGeneratedAt: pending.snapshot.generatedAt,
            claimReferences: pending.snapshot.claimReferences
        )
    }

    /// Revokes only the matching pending action. It performs no filesystem I/O
    /// and grants no cleanup authority.
    @discardableResult
    public func release(_ delivery: FrozenKnowledgeSnapshotDelivery) -> Bool {
        guard let pending = pendingByToken[delivery.token],
              pending.plan.exactTarget.path == delivery.exactDisplayPath else {
            return false
        }
        pendingByToken.removeValue(forKey: delivery.token)
        return true
    }

    private func uniqueToken() -> KnowledgeSnapshotDeliveryToken {
        while true {
            let candidate = KnowledgeSnapshotDeliveryToken(UUID())
            if pendingByToken[candidate] == nil { return candidate }
        }
    }
}
