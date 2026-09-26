import Foundation
import OpenBotsDomain
@testable import OpenBotsServices
import Testing

@Suite("Handoff fence")
struct HandoffFenceTests {
    let date = Date(timeIntervalSince1970: 5_000)
    func bot(_ name: String, role: String) throws -> Teammate {
        try Teammate(id: TeammateID(UUID()), profile: TeammateProfile(displayName: name, role: role),
            appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 3, silhouette: "round",
                paletteToken: "sky", eyeDialect: "bright", nonColorIdentityCue: "crest", accessibleIdentityDescription: "Round"),
            createdAt: date, updatedAt: date)
    }
    let fence = """
    ```handoff
    {"to": "Ada", "goal": "Write a haiku about teamwork", "constraints": ["Three lines"], "inputs": [],
     "requestedOutput": "The haiku only", "exclusions": ["No title"], "boundary": "Stop after one haiku"}
    ```
    """

    @Test("The fence is split off the reply; text without a fence is untouched")
    func split() {
        let split = HandoffFence.split("I'll ask Ada.\n\n" + fence)
        #expect(split.strippedText == "I'll ask Ada.\n\n")
        #expect(split.fenceBody?.contains("\"to\": \"Ada\"") == true)
        #expect(HandoffFence.split("Plain reply.")
            == HandoffFenceSplit(strippedText: "Plain reply.", fenceBody: nil))
        // Only the last fence counts and it must close; an unclosed one stays text.
        let unclosed = HandoffFence.split("Text\n```handoff\n{\"to\": \"Ada\"}")
        #expect(unclosed.fenceBody == nil && unclosed.strippedText == "Text\n```handoff\n{\"to\": \"Ada\"}")
        // A real, closed fence still parses even when a later paragraph merely
        // mentions ```handoff mid-line; that mention is inert and stays as text.
        let mentionAfter = HandoffFence.split(fence + "\n\nJust use a ```handoff block like that.")
        #expect(mentionAfter.fenceBody?.contains("\"to\": \"Ada\"") == true)
        #expect(mentionAfter.strippedText == "\n\nJust use a ```handoff block like that.")
        // "```handoffish" is not an opener: an opener must be a whole line.
        let notAnOpener = HandoffFence.split("```handoffish\n{\"to\": \"Ada\"}\n```")
        #expect(notAnOpener.fenceBody == nil)
        // Two closed fences: the last one wins; the first stays as text.
        let firstFence = "First try.\n\n```handoff\n{\"to\": \"Zed\"}\n```\n\nActually, let me reconsider."
        let twoFences = HandoffFence.split(firstFence + "\n\n" + fence)
        #expect(twoFences.fenceBody?.contains("\"to\": \"Ada\"") == true)
        #expect(twoFences.strippedText == firstFence + "\n\n")
    }

    @Test("The stripped text deletes exactly the fence region and changes nothing else")
    func strippedText() {
        // The newline on either side of the region belongs to the surrounding
        // text, so a reply whose fence ends it keeps its own trailing blank line.
        #expect(HandoffFence.split("Hi\n\n" + fence).strippedText == "Hi\n\n")
        // Leading whitespace survives. That is the point: the saved reply must
        // still extend what was already streamed.
        #expect(HandoffFence.split("  Hi\n\n" + fence).strippedText == "  Hi\n\n")
        // Text after the fence is kept where it was, not rejoined with "\n\n".
        #expect(HandoffFence.split("Hi\n" + fence + "\nDone.").strippedText == "Hi\n\nDone.")
        // The opener on the very first line, with text after the closer: there
        // is nothing before the region to keep, and the newline that followed
        // the closer belongs to what comes after it.
        #expect(HandoffFence.split(fence + "\nAfter.").strippedText == "\nAfter.")
        // A second, dangling opener is text; only the closed region is deleted.
        let dangling = HandoffFence.split("A\n" + fence + "\n```handoff")
        #expect(dangling.strippedText == "A\n\n```handoff")
        // A fence-only reply strips to nothing; the caller supplies the standing
        // sentence, because "blank" is the caller's decision, not the split's.
        #expect(HandoffFence.split(fence).strippedText.isEmpty)
        // No fence at all leaves the text identical.
        #expect(HandoffFence.split("Plain.").strippedText == "Plain.")
    }

    @Test("A fence becomes a brief addressed to a member by display name")
    func parse() throws {
        let mira = try bot("Mira", role: "Lead"), ada = try bot("Ada", role: "Verifier")
        let body = try #require(HandoffFence.split(fence).fenceBody)
        let parsed = try HandoffFence.brief(from: body, members: [ada, mira], sender: mira)
        #expect(parsed.receiver.id == ada.id)
        #expect(parsed.brief.goal == "Write a haiku about teamwork" && parsed.brief.exclusions == ["No title"])
        #expect(parsed.brief.stopOrApprovalBoundary == "Stop after one haiku")
        // Case-insensitive name resolves to the one member; unknown or self is
        // refused; malformed JSON is refused.
        let lowercasedName = try HandoffFence.brief(from: body.replacingOccurrences(of: "\"Ada\"", with: "\"ada\""), members: [ada, mira], sender: mira)
        #expect(lowercasedName.receiver.id == ada.id)
        #expect(throws: HandoffFenceError.unknownReceiver("Zed")) {
            _ = try HandoffFence.brief(from: body.replacingOccurrences(of: "\"Ada\"", with: "\"Zed\""), members: [ada, mira], sender: mira)
        }
        #expect(throws: HandoffFenceError.receiverIsSender) {
            _ = try HandoffFence.brief(from: body.replacingOccurrences(of: "\"Ada\"", with: "\"Mira\""), members: [ada, mira], sender: mira)
        }
        #expect(throws: HandoffFenceError.malformed) { _ = try HandoffFence.brief(from: "{not json", members: [ada, mira], sender: mira) }
        #expect(throws: HandoffFenceError.self) {
            _ = try HandoffFence.brief(from: body.replacingOccurrences(of: "Write a haiku about teamwork", with: ""), members: [ada, mira], sender: mira)
        }
    }

    @Test("Two members matching the name case-insensitively are refused, not silently guessed")
    func ambiguousReceiver() throws {
        let mira = try bot("Mira", role: "Lead")
        let adaUpper = try bot("Ada", role: "Verifier"), adaLower = try bot("ada", role: "Researcher")
        let body = try #require(HandoffFence.split(fence).fenceBody)
        #expect(throws: HandoffFenceError.ambiguousReceiver("Ada")) {
            _ = try HandoffFence.brief(from: body, members: [adaUpper, adaLower, mira], sender: mira)
        }
    }

    @Test("The rendered brief and the prompt blocks name the parties and every field")
    func render() throws {
        let mira = try bot("Mira", role: "Lead"), ada = try bot("Ada", role: "Verifier")
        let brief = try HandoffBrief(goal: "Write a haiku about teamwork", constraints: ["Three lines"], inputReferences: ["The plan above"],
            requestedOutput: "The haiku only", exclusions: ["No title"], stopOrApprovalBoundary: "Stop after one haiku")
        let text = HandoffFence.renderBrief(brief, sender: mira, receiver: ada)
        #expect(text.hasPrefix("Handoff from Mira to Ada."))
        for needle in ["Goal: Write a haiku about teamwork", "Constraints:\n- Three lines", "Inputs:\n- The plan above",
                       "Requested output: The haiku only", "Exclusions:\n- No title", "Stop or ask before: Stop after one haiku"] {
            #expect(text.contains(needle), Comment(rawValue: needle))
        }
        let instructions = HandoffFence.instructions(for: [ada, mira], lead: mira)
        #expect(instructions.contains("```handoff") && instructions.contains("\"to\"") && instructions.contains("Ada"))
        #expect(!instructions.contains("Mira\""), "the lead is not offered as a receiver")
        // The workspace dispatches the brief, so the lead is never told the
        // user has a button to press before the member sees it.
        #expect(instructions.contains(
            "the brief is handed to the member for you and kept in the openable work record"))
        #expect(instructions.contains("up to \(HandoffRecord.maximumChainHops) member legs")
            && instructions.contains("Never request parallel fan-out"))
        #expect(!instructions.contains("send or decline"))
        // The member's leg is a fresh session with the brief as its only input,
        // so the lead is told to make the brief carry everything.
        #expect(instructions.contains("The member receives nothing but this brief")
            && instructions.contains("never point at something \"given earlier\" or \"discussed above\""))
        // The claim rule binds the reply that carries the block. On the turn
        // after the member has answered, the results block below applies.
        #expect(instructions.contains("In the reply that carries the block, do not claim the member has already answered."))
        #expect(!instructions.contains("Never claim the member has already answered."))
        // The member's reply is the report to the lead: kept on the
        // record, compiled by the lead for the user, so the leg says so and
        // asks for the whole answer, once.
        let leg = HandoffFence.legInstructions(sender: mira)
        #expect(leg.contains("Mira, the lead, handed you this brief"))
        #expect(leg.contains("Your answer goes back to Mira, who compiles it for the user; write it complete, "
            + "with every name, number and link you found, and the full path of any file you made; no preface, no closing offer."))
        #expect(!leg.contains("shown to the user in this conversation as yours"))
        let report = HandoffFence.reportInstructions(member: ada)
        #expect(report.contains("Ada, a member of your team, has reported back on the brief you handed off")
            && report.contains("the user has not seen them") && report.contains("answer the user once, in first person")
            && report.contains("You cannot hand off again"))
        let continuation = HandoffFence.reportInstructions(member: ada, remainingHops: 2)
        #expect(continuation.contains("You have 2 member legs left")
            && continuation.contains("intermediate reply stays in the work record: do not compile an answer yet"))
        let record = HandoffRecord(handoff: try Handoff(rehydrating: HandoffProvenance(handoffID: HandoffID(UUID()), legID: HandoffLegID(UUID()),
                originConversationID: ConversationID(UUID()), senderID: mira.id, receiverID: ada.id, createdAt: date),
            brief: brief, state: .succeeded, recovery: nil, lastTransitionAt: date, resultSummary: "Silent hands align", completedAt: date, returnedAt: nil),
            sourceMessageID: nil)
        let results = HandoffFence.returnedResults([record], members: [ada, mira])
        #expect(results.contains("Results returned from members") && results.contains("Ada") && results.contains("Silent hands align"))
        // The block is a standing reference, not an order to summarise: the
        // lead compiles what came back when the user asks about it, keeps the
        // specifics, and hands the task off again when the user asks again.
        #expect(results.contains("If the user's message is about these results, summarise them in your own words at chat "
            + "length and keep every name, number and link the member gave; the user does not see the member's own message, "
            + "so leave out nothing they asked for."))
        #expect(results.contains("If the user asks you to try again or gives new information, hand the task off again with "
            + "a complete brief and do not repeat the old result."))
        #expect(!results.contains("Summarise what came back"))
        #expect(HandoffFence.returnedResults([], members: [ada, mira]).isEmpty)
    }
}
