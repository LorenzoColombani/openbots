import Foundation
import OpenBotsContent
import OpenBotsDomain

/// The two halves of one explicit, qualified snapshot operation share the same
/// trusted validator and frozen context. Constructing this value neither shows
/// Knowledge UI nor selects a payload/destination, grants sharing, or writes.
public struct QualifiedMemorySnapshotServices: Sendable {
    public let sharing: MemoryClaimSnapshotSharingService
    public let delivery: KnowledgeSnapshotDeliveryBroker

    init(sharing: MemoryClaimSnapshotSharingService, delivery: KnowledgeSnapshotDeliveryBroker) {
        self.sharing = sharing; self.delivery = delivery
    }
}

extension StoragePersistenceContext {
    /// Production composition for a future explicit snapshot-selection route.
    /// The host supplies its already frozen bot/conversation/project context and
    /// selected metadata. Only renderSelectedDocuments' exact subset is loaded;
    /// owner-inspection snapshots never become export authority through this API.
    /// An exact destination still needs the broker's separate freeze/create flow.
    public func qualifiedMemorySnapshotServices(
        context: ReadContextReceipt,
        locationChecker: any LocationEnvironmentChecking = FoundationLocationEnvironmentChecker(),
        clock: @escaping @Sendable () -> Date = Date.init
    ) async throws -> QualifiedMemorySnapshotServices {
        try Task.checkCancellation()
        try await readContextRepository.revalidateReadContext(context)
        let support = applicationSupportRoot
        let authority = try await Task.detached(priority: .userInitiated) {
            try AuthoritativeMarkdownRootVerifier().verify(
                support.url.appending(path: MemoryAuthorityContract.appOwnedMarkdownV1.relativeRoot,
                                      directoryHint: .isDirectory), inside: support)
        }.value
        try Task.checkCancellation()
        try await readContextRepository.revalidateReadContext(context)
        let evidence = MemoryEvidenceVerifier(messages: messageRepository, teammates: teammateRepository,
                                              contexts: readContextRepository)
        let sharing = MemoryClaimSnapshotSharingService(memory: memoryRepository,
            intents: memoryPublicationIntentRepository, contexts: readContextRepository, evidence: evidence,
            authority: authority, context: context, clock: clock)
        return QualifiedMemorySnapshotServices(sharing: sharing,
            delivery: KnowledgeSnapshotDeliveryBroker(locationChecker: locationChecker, sharing: sharing))
    }
}
