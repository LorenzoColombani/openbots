import Foundation

/// A durable handoff: the state machine plus the message and run rows it is
/// anchored to. Persistence stores exactly this; services mutate it through
/// `apply` and the repository's expected-state update.
public struct HandoffRecord: Equatable, Sendable, Identifiable {
    /// Sequential member legs per user request. A report turn may request the
    /// next leg, but only the final report answers the user.
    public static let maximumChainHops = 4
    public private(set) var handoff: Handoff
    public let chainID: HandoffID
    public let parentHandoffID: HandoffID?
    public let hopCount: Int
    public let originalUserMessageID: MessageID?
    /// The lead's reply that carried the brief.
    public let sourceMessageID: MessageID?
    /// The rendered brief, authored by the sender, once the leg was sent.
    public var briefMessageID: MessageID?
    /// The receiver's reply, once saved.
    public var replyMessageID: MessageID?
    /// The receiver's text turn.
    public var runID: RunID?

    public var id: HandoffID { handoff.provenance.handoffID }
    public var legID: HandoffLegID { handoff.provenance.legID }
    public var state: HandoffState { handoff.state }
    public var conversationID: ConversationID { handoff.provenance.originConversationID }
    public var senderID: TeammateID { handoff.provenance.senderID }
    public var receiverID: TeammateID { handoff.provenance.receiverID }
    public var brief: HandoffBrief { handoff.brief }

    public init(handoff: Handoff, sourceMessageID: MessageID?, briefMessageID: MessageID? = nil,
                replyMessageID: MessageID? = nil, runID: RunID? = nil,
                chainID: HandoffID? = nil, parentHandoffID: HandoffID? = nil,
                hopCount: Int = 1, originalUserMessageID: MessageID? = nil) {
        self.handoff = handoff
        self.chainID = chainID ?? handoff.provenance.handoffID
        self.parentHandoffID = parentHandoffID
        self.hopCount = hopCount
        self.originalUserMessageID = originalUserMessageID
        self.sourceMessageID = sourceMessageID
        self.briefMessageID = briefMessageID
        self.replyMessageID = replyMessageID
        self.runID = runID
    }

    public mutating func apply(_ event: HandoffEvent) throws {
        try handoff.apply(event)
    }
}
