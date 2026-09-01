import Combine
import Foundation
import OpenBotsDomain
import OpenBotsServices

/// Owns only one visible conversation's durable selection. Pending writes
/// never become usable memory scope, and navigation cannot retarget a write.
@MainActor
public final class ConversationContextModel: ObservableObject {
    @Published public private(set) var selection: ConversationContextSelection?
    @Published public private(set) var isBusy = false
    @Published public private(set) var failure: String?
    @Published public private(set) var needsExplicitClear = false
    private let service: any ConversationContextServing
    private var target: (conversation: ConversationID, teammate: TeammateID)?
    private var generation: UInt64 = 0
    private var invalidatedRevision: UInt64?

    public init(service: any ConversationContextServing) { self.service = service }

    public var canSelect: Bool {
        target != nil && !isBusy && (selection != nil || invalidatedRevision != nil)
    }

    public func activate(conversationID: UUID?, teammateID: UUID?) {
        generation &+= 1
        let ticket = generation
        selection = nil
        invalidatedRevision = nil
        failure = nil
        needsExplicitClear = false
        guard let conversationID, let teammateID else {
            target = nil
            isBusy = false
            return
        }
        let conversation = ConversationID(conversationID)
        let teammate = TeammateID(teammateID)
        target = (conversation, teammate)
        isBusy = true
        Task {
            do {
                let loaded = try await service.load(conversationID: conversation, teammateID: teammate)
                guard ticket == generation else { return }
                guard loaded.conversationID == conversation, loaded.teammateID == teammate else {
                    throw RepositoryError.unavailable(reason: "Context identity mismatch")
                }
                selection = loaded
                isBusy = false
            } catch {
                guard ticket == generation else { return }
                record(error)
            }
        }
    }

    public func select(projectID: UUID?, teamID: UUID?) {
        guard canSelect, let target,
              let revision = selection?.revision ?? invalidatedRevision else { return }
        let ticket = generation
        isBusy = true
        failure = nil
        Task {
            do {
                let saved = try await service.save(
                    conversationID: target.conversation, teammateID: target.teammate,
                    projectID: projectID.map(ProjectID.init), teamID: teamID.map(TeamID.init),
                    expectedRevision: revision
                )
                guard ticket == generation else { return }
                guard saved.conversationID == target.conversation,
                      saved.teammateID == target.teammate else {
                    throw RepositoryError.unavailable(reason: "Context identity mismatch")
                }
                invalidatedRevision = nil
                needsExplicitClear = false
                selection = saved
                isBusy = false
            } catch {
                guard ticket == generation else { return }
                // Never continue showing an old scope after validation fails.
                selection = nil
                invalidatedRevision = nil
                record(error)
            }
        }
    }

    public func reload() {
        activate(conversationID: target?.conversation.rawValue, teammateID: target?.teammate.rawValue)
    }

    public func clearUnavailableContext() { select(projectID: nil, teamID: nil) }

    private func record(_ error: Error) {
        isBusy = false
        if case ConversationContextError.selectionInvalidated(let revision) = error {
            invalidatedRevision = revision
            needsExplicitClear = true
            failure = "This conversation’s saved context is no longer available. Clear it or choose a current membership."
        } else {
            failure = "The work context could not be verified or saved. Reload before choosing again."
        }
    }
}
