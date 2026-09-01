import Foundation
import OpenBotsContent
import OpenBotsDomain

/// Routes explicit local memory requests before the provider adapter. Ordinary
/// unrelated chat keeps its existing route; no local answer pretends to be Claude.
public actor MemoryLocalConversationService: ClaudeTextReplyServing {
    private let fallback: any ClaudeTextReplyServing
    private let corrections: (any ClaudeTextReplyServing)?
    private let memory: any MemoryRepository
    private let intents: any MemoryPublicationIntentRepository
    private let contexts: any ReadContextRepository
    private let selections: any ConversationContextRepository
    private let messages: any MessageRepository
    private let teammates: any TeammateRepository
    private let publications: any MemoryConversationPublicationRepository
    private let authority: VerifiedAuthoritativeMarkdownRoot?
    private let clock: @Sendable () -> Date
    private var active: Set<TeammateID> = []

    public init(fallback: any ClaudeTextReplyServing, corrections: (any ClaudeTextReplyServing)? = nil,
                memory: any MemoryRepository, intents: any MemoryPublicationIntentRepository,
                contexts: any ReadContextRepository, selections: any ConversationContextRepository,
                messages: any MessageRepository, teammates: any TeammateRepository,
                publications: any MemoryConversationPublicationRepository,
                authority: VerifiedAuthoritativeMarkdownRoot?, clock: @escaping @Sendable () -> Date = Date.init) {
        self.fallback = fallback; self.corrections = corrections; self.memory = memory; self.intents = intents
        self.contexts = contexts; self.selections = selections; self.messages = messages
        self.teammates = teammates; self.publications = publications; self.authority = authority
        self.clock = { MemoryPersistenceTimestamp.normalized(clock()) }
    }

    public nonisolated static func inquiry(_ text: String) -> MemoryConversationIntent? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "?"))
        switch normalized {
        case "what do you remember about me", "what do you assume about me", "what do you think about me": return .overview
        case "show my memory history", "show withdrawn memories": return .historyOverview
        case "why did you say that", "why did you say this": return .explanation
        default: return nil
        }
    }

    public func messageProvenance(conversationID: ConversationID, messageIDs: [MessageID])
        async throws -> [TextTurnMessageProvenance] {
        try await fallback.messageProvenance(conversationID: conversationID, messageIDs: messageIDs)
    }

    public func sendText(_ submission: ClaudeTextTurnSubmission,
                         onProgress: @escaping @Sendable (ClaudeTextTurnProgress) async -> Void) async -> ClaudeTextTurnResult {
        guard active.insert(submission.teammateID).inserted else { return .init(outcome: .failed(.busy)) }
        defer { active.remove(submission.teammateID) }
        if MemoryEvidenceVerifier.recognizesUserCommand(submission.text) {
            guard let corrections else { return .init(outcome: .failed(.memoryPublicationNotReady)) }
            return await corrections.sendText(submission, onProgress: onProgress)
        }
        guard let intent = Self.inquiry(submission.text) else {
            return await fallback.sendText(submission, onProgress: onProgress)
        }
        guard submission.attachmentIDs.isEmpty else { return .init(outcome: .failed(.attachmentsNotSupported)) }
        do {
            try Task.checkCancellation()
            // Recover the already committed pair if a client missed its final
            // callback. This is a historical retry, never fresh source authority.
            if let prior = try await publications.memoryConversationPublication(
                messageID: submission.userMessageID, conversationID: submission.conversationID) {
                guard prior.userMessage.id == submission.userMessageID,
                      prior.authority.teammateID == submission.teammateID,
                      prior.publication.receipt.intent == intent,
                      prior.userMessage.parts.count == 1,
                      case let .text(original) = prior.userMessage.parts[0].content,
                      original.utf8.elementsEqual(submission.text.utf8) else {
                    return .init(outcome: .failed(.invalidInput))
                }
                await onProgress(.userMessageSaved(prior.userMessage))
                await onProgress(.assistantMessageSaved(prior.replyMessage))
                return .init(outcome: .completed, savedUserMessage: prior.userMessage,
                             savedReplyMessage: prior.replyMessage)
            }
            guard let authority else { return .init(outcome: .failed(.contextUnavailable)) }
            guard let teammate = try await teammates.teammate(id: submission.teammateID) else {
                return .init(outcome: .failed(.unavailable))
            }
            let page = try await messages.page(conversationID: submission.conversationID, request: PageRequest(limit: 12))
            let previous = page.elements.last?.sequence ?? 0
            guard previous < Int64.max - 1 else { return .init(outcome: .failed(.persistenceFailed)) }
            let selection = try await selections.loadContext(conversationID: submission.conversationID)
            let snapshot = try await contexts.loadReadContextCandidates(ReadContextRequest(
                conversationID: submission.conversationID, teammateID: teammate.id,
                profileRevision: teammate.profile.revision, selection: selection, beforeSequence: previous + 1))
            await onProgress(.stage(.selectingContext))
            let refs: [MemoryClaimReference]
            var explained: UUID?
            var limitation: MemoryExplanationLimitation?
            if intent == .explanation {
                if let lastReply = page.elements.last(where: { $0.author != .user }),
                   let record = try await publications.memoryConversationPublication(messageID: lastReply.id,
                        conversationID: submission.conversationID) {
                    guard record.authority.conversationID == submission.conversationID,
                          record.authority.teammateID == teammate.id else {
                        throw MemoryConversationPublicationError.invalidReceipt
                    }
                    if record.authority.selectedProjectID != snapshot.receipt.selectedProjectID {
                        refs = []; limitation = .sourcesUnavailable
                    } else if record.publication.receipt.dependencies.count > MemoryPublicationLimits.referencesPerUnit {
                        refs = []; limitation = .lineageUnverifiable
                    } else {
                        explained = record.publication.receipt.id
                        refs = record.publication.receipt.dependencies.map(\.reference)
                    }
                } else {
                    refs = []
                }
            } else {
                refs = try await selectedClaims(snapshot, includeWithdrawn: intent == .historyOverview)
            }
            let prepared: PreparedPublication
            do {
                prepared = try await preparePublication(intent: intent, references: refs, explained: explained,
                    limitation: limitation, base: snapshot.receipt, authority: authority)
            } catch {
                guard intent == .explanation, limitation == nil, let reason = explanationLimitation(for: error) else { throw error }
                // This is a new static local projection, not permission to reuse
                // old claims. Its fresh scope-only authority must still pass.
                prepared = try await preparePublication(intent: intent, references: [], explained: nil,
                    limitation: reason, base: snapshot.receipt, authority: authority)
            }
            try Task.checkCancellation()
            await onProgress(.stage(.saving))
            let validation = MemoryConversationPublicationValidation(authority: prepared.authority,
                publicationDigest: try MemoryConversationPublicationValidation.digest(of: prepared.publication),
                userSourceStamps: prepared.stamps, checkedAt: clock())
            let record = try await publications.appendMemoryConversationPublication(.init(publication: prepared.publication,
                userMessageID: submission.userMessageID, userPartID: MessagePartID(UUID()), replyPartID: MessagePartID(UUID()),
                userText: submission.text, expectedPreviousSequence: previous, validation: validation), now: clock())
            await onProgress(.userMessageSaved(record.userMessage))
            await onProgress(.assistantMessageSaved(record.replyMessage))
            return .init(outcome: .completed, savedUserMessage: record.userMessage, savedReplyMessage: record.replyMessage)
        } catch is CancellationError { return .init(outcome: .stopped) }
        catch is ReadContextError { return .init(outcome: .failed(.contextChanged)) }
        catch is MemoryConversationPublicationError { return .init(outcome: .failed(.contextUnavailable)) }
        catch { return .init(outcome: .failed(.persistenceFailed)) }
    }

    private struct PreparedPublication {
        let publication: MemoryConversationPublication
        let authority: ReadContextReceipt
        let stamps: [MemoryPublicationUserMessageEvidence]
    }

    private func preparePublication(intent: MemoryConversationIntent, references: [MemoryClaimReference],
                                    explained: UUID?, limitation: MemoryExplanationLimitation?,
                                    base: ReadContextReceipt, authority: VerifiedAuthoritativeMarkdownRoot)
        async throws -> PreparedPublication {
        // An unavailable old head must not be silently replaced by its successor.
        guard references.allSatisfy({ reference in base.memoryDocuments.contains {
            $0.documentID == reference.documentID && $0.revision == reference.documentRevision
                && $0.contentDigest == reference.contentDigest
        } }) else { throw MemoryConversationPublicationError.sourceUnavailable }
        let documentIDs = Array(Set(references.map(\.documentID))).sorted { $0.persistedValue < $1.persistedValue }
        let selected = try base.selecting(messageIDs: [], memoryDocumentIDs: documentIDs).qualifying(with: references)
        try await contexts.revalidateReadContext(selected)
        let request = MemoryPublicationContext(runID: RunID(UUID()), messageID: MessageID(UUID()),
            teammateID: selected.teammateID, selectedProjectID: selected.selectedProjectID, intent: intent,
            admittedReferences: references, relevantReferences: references, explainedReceiptID: explained,
            explanationLimitation: limitation, now: clock())
        let verifier = MemoryEvidenceVerifier(messages: messages, teammates: teammates, contexts: contexts)
        let resolver = MemoryConversationResolver(memory: memory, intents: intents, contexts: contexts,
            publications: publications, evidence: verifier, authority: authority, context: selected, clock: clock)
        let publisher = MemoryConversationPublicationService(resolver: resolver)
        let units: [MemoryPublicationUnit]
        if let limitation { units = [MemoryConversationPublicationRendering.limitationUnit(limitation)] }
        else if references.isEmpty {
            units = intent == .explanation ? [.init(kind: .explanation, references: [])] : []
        } else {
            units = [.init(kind: intent == .explanation ? .explanation : .overview, references: references)]
        }
        let publication = try await publisher.publish(.init(units: units), context: request)
        let stamps = try await userStamps(publication.receipt)
        guard try await publisher.revalidate(publication, context: request) else {
            throw MemoryConversationPublicationError.publicationChanged
        }
        return PreparedPublication(publication: publication, authority: selected, stamps: stamps)
    }

    private func explanationLimitation(for error: any Error) -> MemoryExplanationLimitation? {
        if let error = error as? MemoryConversationPublicationError {
            switch error {
            case .sourceUnavailable, .staleReference, .scopeDenied, .policyDenied, .publicationChanged:
                return .sourcesUnavailable
            case .unknownLineage, .cyclicLineage, .invalidReceipt, .boundsExceeded:
                return .lineageUnverifiable
            default: return nil
            }
        }
        if let error = error as? ReadContextError, error == .staleReferences || error == .unavailable {
            return .sourcesUnavailable
        }
        if error is AuthoritativeMarkdownError { return .sourcesUnavailable }
        return nil
    }

    private func selectedClaims(_ snapshot: ReadContextSnapshot, includeWithdrawn: Bool)
        async throws -> [MemoryClaimReference] {
        guard let authority else { throw MemoryConversationPublicationError.sourceUnavailable }
        var references: [MemoryClaimReference] = []
        let codec = MemoryClaimCodec()
        for document in snapshot.memoryDocuments.prefix(3) {
            guard try await !intents.memoryPublicationBlocksUse(documentID: document.id),
                  let committed = try await intents.committedMemoryPublication(documentID: document.id),
                  committed.intent.policyDigest == MemoryClaimAdmissionService.policyDigest else { continue }
            let current = try snapshot.receipt.selecting(messageIDs: [], memoryDocumentIDs: [document.id])
            try await contexts.revalidateReadContext(current)
            let value = try await AuthoritativeMarkdownStore(maximumBytes: 16_384)
                .read(AuthoritativeMarkdownReference(document: document), inside: authority)
            guard let artifact = codec.decode(Data(value.markdown.utf8), expecting: document).artifact else { continue }
            for claim in artifact.claims where includeWithdrawn || claim.validity != .withdrawn {
                guard references.count < 12 else { return references }
                references.append(try codec.reference(for: claim, in: artifact, contentDigest: document.contentDigest))
            }
        }
        return references
    }

    private func userStamps(_ receipt: MemoryPublicationReceipt) async throws -> [MemoryPublicationUserMessageEvidence] {
        var stamps: [MessageID: MemoryPublicationUserMessageEvidence] = [:]
        for source in receipt.dependencies.flatMap(\.sourceStamps) where source.kind == .userMessage {
            guard let uuid = UUID(uuidString: source.sourceID),
                  let message = try await messages.message(id: MessageID(uuid)), message.author == .user,
                  message.parts.count == 1, case let .text(text) = message.parts[0].content,
                  source.contentDigest == MemoryClaimDigests.bytes(Data(text.utf8)) else {
                throw MemoryConversationPublicationError.sourceUnavailable
            }
            stamps[message.id] = try .init(messageID: message.id,
                contentDigest: MemoryClaimDigests.bytes(Data(text.utf8)), updatedAt: message.updatedAt)
        }
        return stamps.values.sorted { $0.messageID.persistedValue < $1.messageID.persistedValue }
    }
}
