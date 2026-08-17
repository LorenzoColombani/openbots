import XCTest
@testable import AgencyKit

/// Two persona rounds (his orders 2026-08-13, remaining-work items 8 + 9):
/// - FIDELITY: a research run failed because the agent silently dropped every
///   quote and genericized the Star Wars references — self-invented caution
///   ABOVE policy. Personas now forbid silent sanitizing and require
///   disclosure of any real omission.
/// - INLINE DELIVERABLES: "otherwise it's not really a chat" — the reply must
///   carry the full product, not a vault path pointer.
final class PersonaDeliveryTests: XCTestCase {
    private func personaFor(_ name: String) throws -> String {
        let store = AgentStore(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-pd-\(UUID().uuidString)"))
        _ = try store.createAgent(name: name, emoji: "🧪", role: "writer")
        let raw = try String(contentsOf: store.agentDir(name).appendingPathComponent("CLAUDE.md"),
                             encoding: .utf8)
        // The template hard-wraps prose — collapse whitespace so phrase
        // assertions can't be broken by a reflow.
        return raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    // MARK: item 8 — fidelity / anti-self-censorship

    func testPersonaForbidsSilentSanitizing() throws {
        let p = try personaFor("probe")
        XCTAssertTrue(p.contains("keep specific NAMED references"),
                      "franchise names, people, titles stay as the source has them")
        XCTAssertTrue(p.contains("Never genericize"),
                      "the silent-summarising failure mode, named")
        XCTAssertTrue(p.contains("Short attributed quotes"),
                      "quotes in his own working documents are normal, not risky")
    }

    func testPersonaRequiresDisclosureOverSilence() throws {
        let p = try personaFor("probe")
        XCTAssertTrue(p.contains("omitted X because Y"),
                      "any real omission is stated IN THE REPLY")
        XCTAssertTrue(p.contains("silently sanitized deliverable is a failed task"),
                      "the priority is explicit: silence is the failure, not the content")
    }

    // MARK: item 9 — the reply IS the deliverable

    func testPersonaMakesTheReplyCarryTheDeliverable() throws {
        let p = try personaFor("probe")
        XCTAssertTrue(p.contains("Your reply IS the deliverable"),
                      "section present")
        XCTAssertTrue(p.contains("A vault path alone is not an answer"),
                      "the pointer-only habit, banned by name")
        XCTAssertTrue(p.contains("FULL product in your chat reply AND save it to the vault"),
                      "both places, every time")
    }

    func testRelayHygieneSurvivesTheInlineRule() throws {
        // BULKY material still goes through a vault note — but the old "one
        // line per recipient" rule is gone. It was half the reason a relayed
        // outbound message arrived empty (2026-08-13): the persona told him to
        // put exact text on one line, and the parser cut it at the newline.
        let p = try personaFor("probe")
        XCTAssertTrue(p.contains("Bulky material (research, a long draft) is better as a vault note"),
                      "the path convention survives for genuinely long material")
        XCTAssertTrue(p.contains("Short exact content"),
                      "but the message to SEND belongs in the relay, where it can't go stale")
    }

    // MARK: the panel failure 2026-08-13

    func testPersonaTeachesMultiLineRelays() throws {
        let p = try personaFor("probe")
        XCTAssertTrue(p.contains("The message MAY span several lines"),
                      "the one-line rule is what truncated the relayed message")
        XCTAssertTrue(p.contains("END RELAY"),
                      "the escape hatch for talking to Lorenzo after a relay")
        XCTAssertFalse(p.contains("one line per recipient"),
                       "the old instruction must be gone, not merely contradicted")
    }

    /// Riker asserted "teammates can't see each other's exchanges", concluded
    /// AnnoyingLibrarian had fabricated a quote, and had to retract. Neither
    /// half of the visibility model was written down anywhere.
    func testPersonaStatesWhatIsAndIsNotVisible() throws {
        let p = try personaFor("probe")
        XCTAssertTrue(p.contains("What you can and cannot see"), "the section exists")
        XCTAssertTrue(p.contains("YOU CAN SEE"), "the positive half — previously unstated")
        XCTAssertTrue(p.contains("YOU CANNOT SEE"))
        XCTAssertTrue(p.contains("never assume a teammate is fabricating"),
                      "the exact wrong inference Riker made, named")
        XCTAssertTrue(p.contains("Lorenzo sees everything"))
    }

    /// Vault audit 2026-08-13: the provenance ledger shows FOUR agents wrote
    /// `handoffs/2026-08-13-agent-to-agent-draft.md`, and even the file
    /// named for annoyinglibrarian was overwritten by two others. Hermes then
    /// went to read a draft it had been pointed at and found someone else's
    /// content there.
    func testPersonaForbidsOverwritingATeammatesNote() throws {
        let p = try personaFor("probe")
        XCTAssertTrue(p.contains("NEVER overwrite a note whose `author:` is a different teammate"),
                      "four agents shared one handoff path and one stamped another's name on it")
        XCTAssertTrue(p.contains("each writes their OWN file"))
        XCTAssertTrue(p.contains("last writer wins and nobody is told"),
                      "name the failure, not just the rule")
    }

    /// The same audit found 7 dead wikilinks, including [[bruno]] and [[nina]] —
    /// agents linking to PEOPLE, which just litters the user's Obsidian graph.
    func testPersonaSaysWikilinksNameNotesNotTeammates() throws {
        let p = try personaFor("probe")
        XCTAssertTrue(p.contains("a wikilink names a NOTE that exists, never a teammate"))
    }

    // MARK: group threads (R3 2026-08-14)

    private func groupPersonas() throws -> (member: String, outsider: String) {
        let store = AgentStore(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-gp-\(UUID().uuidString)"))
        _ = try store.createAgent(name: "member", emoji: "🧪", role: "writer")
        _ = try store.createAgent(name: "outsider", emoji: "🧪", role: "writer")
        _ = try store.createTeam("launch", members: ["member"])
        func read(_ n: String) throws -> String {
            try String(contentsOf: store.agentDir(n).appendingPathComponent("CLAUDE.md"),
                       encoding: .utf8)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        }
        return (try read("member"), try read("outsider"))
    }

    func testMemberPersonaTeachesGroupThreadsAndSingleOwnerGuidance() throws {
        let (member, outsider) = try groupPersonas()
        XCTAssertTrue(member.contains("Group threads"), "the section exists for members")
        XCTAssertTrue(member.contains("[Group thread #"), "the marker the runtime actually sends")
        XCTAssertTrue(member.contains("SINGLE OWNER"),
                      "xAI's failure-mode warning, as guidance — never a manager slot")
        XCTAssertTrue(member.contains("Never appoint yourself the owner"))
        XCTAssertFalse(outsider.contains("Group thread"),
                       "a non-member gets no group teaching — pointing an agent at a "
                       + "capability it lacks invites burned turns")
    }

    func testMemberPersonaVisibilityCoversTheGroupTranscriptRule() throws {
        let (member, _) = try groupPersonas()
        XCTAssertTrue(member.contains("never by reading files"),
                      "group content arrives inside turns")
        XCTAssertTrue(member.contains("a denied read of `teams/` is the fence working"))
    }
}
