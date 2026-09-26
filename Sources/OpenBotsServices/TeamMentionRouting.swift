import Foundation
import OpenBotsDomain

/// Who answers one message in a team conversation.
public struct TeamRecipient: Equatable, Sendable {
    public let teammateID: TeammateID
    public let isLead: Bool
    /// The member's display name when the user addressed them with "@Name".
    public let mentionedName: String?

    public init(teammateID: TeammateID, isLead: Bool, mentionedName: String?) {
        self.teammateID = teammateID
        self.isLead = isLead
        self.mentionedName = mentionedName
    }
}

/// Unmentioned text goes to the designated lead; an explicit mention addresses
/// the named member. One message routes to one member: the earliest "@Name" that names an active member, else the lead.
public enum TeamMentionRouting {
    public static func recipient(for text: String, team: Team, members: [Teammate]) -> TeamRecipient? {
        let active = members.filter { $0.lifecycle == .active && team.memberIDs.contains($0.id) }
        let lowered = text.lowercased()
        var best: (offset: Int, member: Teammate)?
        // Longest names first so "@Ada Lovelace" is not read as "@Ada".
        for member in active.sorted(by: { $0.profile.displayName.count > $1.profile.displayName.count }) {
            let needle = "@" + member.profile.displayName.lowercased()
            var searchRange = lowered.startIndex..<lowered.endIndex
            while let range = lowered.range(of: needle, range: searchRange) {
                if isWordBoundary(lowered, before: range.lowerBound), isWordBoundary(lowered, after: range.upperBound) {
                    let offset = lowered.distance(from: lowered.startIndex, to: range.lowerBound)
                    if best.map({ offset < $0.offset }) ?? true { best = (offset, member) }
                    break
                }
                searchRange = range.upperBound..<lowered.endIndex
            }
        }
        if let best {
            return TeamRecipient(teammateID: best.member.id, isLead: best.member.id == team.leadID,
                                 mentionedName: best.member.profile.displayName)
        }
        guard let lead = active.first(where: { $0.id == team.leadID }) else { return nil }
        return TeamRecipient(teammateID: lead.id, isLead: true, mentionedName: nil)
    }

    private static func isWordBoundary(_ text: String, before index: String.Index) -> Bool {
        guard index > text.startIndex else { return true }
        let previous = text[text.index(before: index)]
        return !(previous.isLetter || previous.isNumber)
    }

    private static func isWordBoundary(_ text: String, after index: String.Index) -> Bool {
        guard index < text.endIndex else { return true }
        let next = text[index]
        return !(next.isLetter || next.isNumber)
    }
}
