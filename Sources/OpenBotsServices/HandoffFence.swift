import Foundation
import OpenBotsDomain

public struct HandoffFenceSplit: Equatable, Sendable {
    /// The original text with the fence region deleted and nothing else
    /// changed. Built by deletion, so it always extends any prefix of the
    /// original that stops at or before the fence, which is what lets a saved
    /// reply replace a checkpoint. It is empty for a fence-only reply.
    public let strippedText: String
    public let fenceBody: String?
}

public enum HandoffFenceError: Error, Equatable, Sendable {
    case malformed
    case unknownReceiver(String)
    case ambiguousReceiver(String)
    case receiverIsSender
    case invalidBrief(String)
}

/// The lead delegates by ending its reply with one fenced ```handoff block of
/// JSON. The block is stripped from the saved reply and becomes a staged
/// handoff, which the workspace hands to the member without asking; the card
/// it leaves in the transcript is the record of what was asked.
public enum HandoffFence {
    public static let fenceLanguage = "handoff"
    public static let summaryLimit = 2_000
    static let standingText = "Handing this off."

    private struct Draft: Decodable {
        let to: String
        let goal: String
        let constraints: [String]?
        let inputs: [String]?
        let requestedOutput: String
        let exclusions: [String]?
        let boundary: String
    }

    /// Splits the last closed fence off the reply. An unclosed fence is text.
    /// `strippedText` deletes the fence region from the original and leaves
    /// every other character, including whitespace, exactly where it was.
    /// An opener/closer must be a whole line by itself: a mid-line mention
    /// such as "use a ```handoff block" or a false match like "```handoffish"
    /// is inert. The last opener that has a closer after it wins.
    public static func split(_ text: String) -> HandoffFenceSplit {
        let opener = "```\(fenceLanguage)"
        let closer = "```"
        let lines = text.components(separatedBy: "\n")
        var openerIndex: Int?
        var closerIndex: Int?
        search: for index in stride(from: lines.count - 1, through: 0, by: -1) {
            guard lines[index].trimmingCharacters(in: .whitespacesAndNewlines) == opener else { continue }
            for after in (index + 1)..<lines.count where lines[after].trimmingCharacters(in: .whitespacesAndNewlines) == closer {
                openerIndex = index
                closerIndex = after
                break search
            }
        }
        guard let openerIndex, let closerIndex else {
            return HandoffFenceSplit(strippedText: text, fenceBody: nil)
        }
        // Exactly the characters from the opener line's start through the
        // closer line's end, and only those: the newline on either side of the
        // region belongs to the text around it and stays.
        var stripped = ""
        if openerIndex > 0 { stripped += lines[..<openerIndex].joined(separator: "\n") + "\n" }
        if closerIndex < lines.count - 1 { stripped += "\n" + lines[(closerIndex + 1)...].joined(separator: "\n") }
        let body = lines[(openerIndex + 1)..<closerIndex].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return HandoffFenceSplit(strippedText: stripped, fenceBody: body)
    }

    public static func brief(from fenceBody: String, members: [Teammate], sender: Teammate) throws -> (receiver: Teammate, brief: HandoffBrief) {
        guard let data = fenceBody.data(using: .utf8), let draft = try? JSONDecoder().decode(Draft.self, from: data) else {
            throw HandoffFenceError.malformed
        }
        let name = draft.to.trimmingCharacters(in: .whitespacesAndNewlines)
        // The same rule that keeps two bots from sharing a name, so a name
        // the roster admitted is one the fence can route.
        let matches = members.filter { TeammateProfile.namesMatch($0.profile.displayName, name) }
        guard !matches.isEmpty else { throw HandoffFenceError.unknownReceiver(name) }
        guard matches.count == 1 else { throw HandoffFenceError.ambiguousReceiver(name) }
        let receiver = matches[0]
        guard receiver.id != sender.id else { throw HandoffFenceError.receiverIsSender }
        do {
            let brief = try HandoffBrief(goal: draft.goal, constraints: draft.constraints ?? [], inputReferences: draft.inputs ?? [],
                requestedOutput: draft.requestedOutput, exclusions: draft.exclusions ?? [], stopOrApprovalBoundary: draft.boundary)
            return (receiver, brief)
        } catch {
            throw HandoffFenceError.invalidBrief(String(describing: error))
        }
    }

    /// The message the sender is recorded as having written to the receiver.
    public static func renderBrief(_ brief: HandoffBrief, sender: Teammate, receiver: Teammate) -> String {
        func list(_ title: String, _ items: [String]) -> String? {
            items.isEmpty ? nil : "\(title):\n" + items.map { "- \($0)" }.joined(separator: "\n")
        }
        return ["Handoff from \(sender.profile.displayName) to \(receiver.profile.displayName).",
                "Goal: \(brief.goal)",
                list("Constraints", brief.constraints),
                list("Inputs", brief.inputReferences),
                "Requested output: \(brief.requestedOutput)",
                list("Exclusions", brief.exclusions),
                "Stop or ask before: \(brief.stopOrApprovalBoundary)"]
            .compactMap { $0 }.joined(separator: "\n")
    }

    /// Appended to the lead's team prompt.
    public static func instructions(for members: [Teammate], lead: Teammate) -> String {
        let names = members.filter { $0.id != lead.id }.map { "\"\($0.profile.displayName)\"" }.sorted().joined(separator: ", ")
        guard !names.isEmpty else { return "" }
        return """

        Delegating: you may hand one task to one member per reply. To do so, answer the user first, then end your reply with exactly one fenced block:
        ```\(fenceLanguage)
        {"to": <one of \(names)>, "goal": "...", "constraints": ["..."], "inputs": ["..."], "requestedOutput": "...", "exclusions": ["..."], "boundary": "..."}
        ```
        The block is not shown to the user as text; the brief is handed to the member for you and kept in the openable work record. The member receives nothing but this brief: it cannot see this conversation, its earlier messages or your memory. Put every name, fact, link and constraint the task needs into the block itself; never point at something "given earlier" or "discussed above". Do not write the block when no delegation is needed. In the reply that carries the block, do not claim the member has already answered. You may ask members sequentially, up to \(HandoffRecord.maximumChainHops) member legs for one user request. Each member reports back to you; after all needed members have answered, compile one answer for the user. Never request parallel fan-out.
        """
    }

    /// Appended to the receiver's prompt for a handoff leg. The reply it
    /// produces is the member's report to the lead: kept whole on the
    /// conversation's record, and compiled by the lead for the user.
    public static func legInstructions(sender: Teammate) -> String {
        """

        \(sender.profile.displayName), the lead, handed you this brief. Do exactly what the brief asks and nothing beyond its boundary. Your answer goes back to \(sender.profile.displayName), who compiles it for the user; write it complete, with every name, number and link you found, and the full path of any file you made; no preface, no closing offer.
        """
    }

    /// Appended to the lead's prompt when it answers a member's report. The
    /// report is the message being answered; the user never saw it.
    public static func reportInstructions(member: Teammate, remainingHops: Int = 0) -> String {
        """

        \(member.profile.displayName), a member of your team, has reported back on the brief you handed off. The original user request and this chain's member reports are supplied with the report; they are between the team, and the user has not seen them. \(remainingHops > 0 ? "If another member is needed to finish the original request, end this turn with one handoff block. You have \(remainingHops) member legs left. That intermediate reply stays in the work record: do not compile an answer yet." : "The member-leg budget is exhausted. You cannot hand off again; say plainly if anything is still missing.") Otherwise answer the user once, in first person, at chat length, with what all members found and every requested name, number and link. Do not say you are waiting or that a member is working. If members produced files the user should have, include their full paths; their saved attachments also carry to your final answer.
        """
    }

    /// The report as the lead receives it: whose it is, on which brief.
    public static func renderReport(_ record: HandoffRecord, member: Teammate, reply: String) -> String {
        "\(member.profile.displayName) reports back on \"\(record.brief.goal)\":\n\n\(reply)"
    }

    /// Said after the returned results when their files are more than one
    /// reply holds: the text comes whole, the files
    /// only up to the limit, and the rest stay in the work record.
    public static func filesLeftOut(_ count: Int) -> String {
        guard count > 0 else { return "" }
        return "\n\(count == 1 ? "1 file" : "\(count) files") from these results will not come with your reply: one reply "
            + "holds at most \(AttachmentDraftSnapshot.maximumAttachments) files, and more are left out if you attach "
            + "files of your own. Every one stays in the work record. Tell the user how many were left out and that "
            + "they can find them there."
    }

    /// Appended to the lead's prompt while members' results wait to be
    /// returned. The lead reads it on whatever the user says next, so it says
    /// when to summarise and when to hand the task off again instead.
    public static func returnedResults(_ records: [HandoffRecord], members: [Teammate]) -> String {
        let lines = records.compactMap { record -> String? in
            guard let summary = record.handoff.resultSummary else { return nil }
            let name = members.first { $0.id == record.receiverID }?.profile.displayName ?? "A member"
            return "- \(name) on \"\(record.brief.goal)\":\n\(summary)"
        }
        guard !lines.isEmpty else { return "" }
        return "\n\nResults returned from members (reference them; do not invent more):\n"
            + lines.joined(separator: "\n")
            + "\nIf the user's message is about these results, summarise them in your own words at chat length and keep every name, number and link the member gave; the user does not see the member's own message, so leave out nothing they asked for."
            + " If the user asks you to try again or gives new information, hand the task off again with a complete brief and do not repeat the old result."
    }
}
