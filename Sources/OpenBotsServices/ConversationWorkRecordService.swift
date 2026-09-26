import Foundation
import OpenBotsDomain

/// The "what happened" record of one conversation: the briefs a lead
/// sent, each member's report, the cards the user answered and every line of
/// what a bot did, in time order. Never the answer bubble; the transcript shows
/// only what is for the user, this shows the rest.
public struct ConversationWorkRecord: Equatable, Sendable {
    public struct Handoff: Equatable, Sendable, Identifiable {
        public let record: HandoffRecord
        public let senderName: String
        public let receiverName: String
        /// The brief as the member received it, once the leg was sent.
        public let briefText: String?
        /// What the member reported back, once saved.
        public let reportText: String?
        public var id: HandoffID { record.id }
    }
    public struct Line: Equatable, Sendable, Identifiable {
        public let id: String
        public let at: Date
        public let botName: String
        public let text: String
    }
    public let handoffs: [Handoff]
    public let approvals: [ApprovalRequest]
    public let lines: [Line]
    public var isEmpty: Bool { handoffs.isEmpty && approvals.isEmpty && lines.isEmpty }
}

public protocol ConversationWorkRecordLoading: Sendable {
    func workRecord(conversationID: ConversationID) async throws -> ConversationWorkRecord
}

public actor ConversationWorkRecordService: ConversationWorkRecordLoading {
    private let handoffs: (any HandoffRepository)?
    private let approvals: (any ApprovalRepository)?
    private let activity: (any RunActivityRepository)?
    private let messages: any MessageRepository
    private let teammates: any TeammateRepository

    public init(handoffs: (any HandoffRepository)?, approvals: (any ApprovalRepository)?,
                activity: (any RunActivityRepository)?, messages: any MessageRepository,
                teammates: any TeammateRepository) {
        self.handoffs = handoffs; self.approvals = approvals; self.activity = activity
        self.messages = messages; self.teammates = teammates
    }

    public func workRecord(conversationID: ConversationID) async throws -> ConversationWorkRecord {
        let records = (try? await handoffs?.records(conversationID: conversationID)) ?? []
        let cards = (try? await approvals?.approvals(conversationID: conversationID, limit: 200)) ?? []
        let activity = (try? await self.activity?.runActivity(conversationID: conversationID, limit: 2_000)) ?? []
        var ids = Set<TeammateID>()
        for record in records { ids.insert(record.senderID); ids.insert(record.receiverID) }
        for line in activity { ids.insert(line.teammateID) }
        var names: [TeammateID: String] = [:]
        // A bot Delete kept for its team history is still found, emptied and
        // named "Deleted bot"; only a bot with no row
        // at all is a former member.
        for id in ids {
            names[id] = (try? await teammates.teammate(id: id))?.profile.displayName ?? "Former member"
        }
        let name = { (id: TeammateID) in names[id] ?? "Former member" }
        var handoffEntries: [ConversationWorkRecord.Handoff] = []
        for record in records {
            // A message that cannot be read leaves a gap, never an empty record.
            var brief: Message?
            if let id = record.briefMessageID { brief = try? await messages.message(id: id) }
            var report: Message?
            if let id = record.replyMessageID { report = try? await messages.message(id: id) }
            handoffEntries.append(.init(record: record, senderName: name(record.senderID),
                receiverName: name(record.receiverID),
                briefText: brief.map(Self.text), reportText: report.map(Self.text)))
        }
        handoffEntries.sort { $0.record.handoff.provenance.createdAt < $1.record.handoff.provenance.createdAt }
        let lines = activity.map { line in
            ConversationWorkRecord.Line(id: line.id, at: line.recordedAt, botName: name(line.teammateID), text: line.line)
        }
        return ConversationWorkRecord(handoffs: handoffEntries, approvals: cards.sorted { $0.requestedAt < $1.requestedAt }, lines: lines)
    }

    private static func text(_ message: Message) -> String {
        message.parts.compactMap { part -> String? in
            if case .text(let text) = part.content { return text }
            return nil
        }.joined(separator: "\n\n")
    }
}
