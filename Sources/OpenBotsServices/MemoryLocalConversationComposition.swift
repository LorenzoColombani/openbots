import Foundation
import OpenBotsContent
import OpenBotsDomain

extension StoragePersistenceContext {
    /// Adds the provider-independent local memory routes. A missing optional
    /// content root disables only these routes, never healthy chat startup.
    public func localMemoryConversationService(fallback: any ClaudeTextReplyServing,
        onRecovery: @escaping @Sendable (MemoryLocalOperationRecoveryReport) async -> Void = { _ in })
        async -> MemoryLocalConversationService {
        let support = applicationSupportRoot
        let authority = try? await Task.detached(priority: .userInitiated) {
            try AuthoritativeMarkdownRootVerifier().verify(
                support.url.appending(path: MemoryAuthorityContract.appOwnedMarkdownV1.relativeRoot,
                                      directoryHint: .isDirectory), inside: support)
        }.value
        let corrections = authority.map {
            MemoryLocalCorrectionService(corrections: memoryLocalCorrectionRepository,
                memory: memoryRepository, intents: memoryPublicationIntentRepository,
                contexts: readContextRepository, conversationContexts: conversationContextRepository,
                teammates: teammateRepository, messages: messageRepository, authority: $0,
                publications: memoryConversationPublicationRepository)
        }
        if let corrections {
            let recovery = MemoryLocalOperationRecoveryService(repository: memoryLocalCorrectionRepository,
                                                               corrections: corrections)
            await onRecovery(await recovery.recover())
        } else {
            // Content trouble does not make healthy chat storage unusable. No
            // local operation is retried, cleared or reported saved in this case.
            await onRecovery(.unavailable)
        }
        return MemoryLocalConversationService(fallback: fallback, corrections: corrections,
            memory: memoryRepository, intents: memoryPublicationIntentRepository,
            contexts: readContextRepository, selections: conversationContextRepository,
            messages: messageRepository, teammates: teammateRepository,
            publications: memoryConversationPublicationRepository, authority: authority)
    }
}
