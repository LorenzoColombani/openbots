import XCTest
@testable import AgencyKit

final class MentionsTests: XCTestCase {
    private let agents = [
        Agent(name: "alfredo", emoji: "🧑‍🍳", role: "r", model: nil, sessionID: nil),
        Agent(name: "annoyinglibrarian", emoji: "📚", role: "r", model: nil, sessionID: nil),
        Agent(name: "bruno", emoji: "✍️", role: "r", model: nil, sessionID: nil),
    ]

    func testLeadingAtSuggests() {
        let s = Mentions.suggestions(draft: "@a", agents: agents, thread: "nina")
        XCTAssertEqual(s.map(\.name), ["alfredo", "annoyinglibrarian"])
    }

    /// The live gap (2026-08-13): "hey once @annoyinglibrarian…" — a mention
    /// mid-sentence, exactly how Lorenzo types — got no suggestions at all.
    func testMidSentenceAtSuggests() {
        let s = Mentions.suggestions(draft: "hey once @anno", agents: agents, thread: "nina")
        XCTAssertEqual(s.map(\.name), ["annoyinglibrarian"])
    }

    func testEmailLikeAtDoesNotSuggest() {
        XCTAssertEqual(Mentions.suggestions(draft: "mail lorenzo@a", agents: agents, thread: "nina"), [])
    }

    func testBareAtDoesNotSuggest() {
        XCTAssertEqual(Mentions.suggestions(draft: "hello @", agents: agents, thread: "nina"), [])
    }

    func testCompletedMentionFollowedBySpaceStopsSuggesting() {
        XCTAssertEqual(Mentions.suggestions(draft: "@alfredo can you", agents: agents, thread: "nina"), [])
    }

    func testExactNameExcludedSoReturnSends() {
        XCTAssertEqual(Mentions.suggestions(draft: "@alfredo", agents: agents, thread: "nina"), [])
    }

    func testSelfExcluded() {
        XCTAssertEqual(Mentions.suggestions(draft: "@brun", agents: agents, thread: "bruno"), [])
    }

    func testFragmentIsCaseInsensitive() {
        let s = Mentions.suggestions(draft: "ping @Anno", agents: agents, thread: "nina")
        XCTAssertEqual(s.map(\.name), ["annoyinglibrarian"])
    }

    func testCompleteReplacesOnlyTheTrailingFragment() {
        let done = Mentions.complete(draft: "hey once @anno", with: agents[1])
        XCTAssertEqual(done, "hey once @annoyinglibrarian ")
    }

    func testCompleteAtStart() {
        XCTAssertEqual(Mentions.complete(draft: "@al", with: agents[0]), "@alfredo ")
    }

    /// Reviewer #5: the field editor can lag the binding — a chip built for
    /// one fragment must never clobber a draft that has since moved on.
    func testStaleClickGuardRefusesMismatchedFragment() {
        let echo2 = Agent(name: "echo2", emoji: "📣", role: "r", model: nil, sessionID: nil)
        let moved = Mentions.complete(draft: "hey @ee", with: echo2, ifFragment: "e")
        XCTAssertEqual(moved, "hey @ee", "draft moved since the chip was built — no-op")
        let fresh = Mentions.complete(draft: "hey @e", with: echo2, ifFragment: "e")
        XCTAssertEqual(fresh, "hey @echo2 ")
    }

    func testFragmentIsLeadingDistinguishesRelayFromMention() {
        XCTAssertTrue(Mentions.fragmentIsLeading(in: "@brun"))
        XCTAssertFalse(Mentions.fragmentIsLeading(in: "hey once @brun"))
    }
}

/// Display names as functional @-names (his ask 2026-08-13, relayed via the
/// cleanup task): suggestions match them, relays resolve them — but the
/// HANDLE stays the address completion inserts.
extension MentionsTests {
    private func team() -> [Agent] {
        [Agent(name: "bruno", emoji: "🖋", role: "writer", model: nil, sessionID: nil,
               displayName: "Bruno the Writer"),
         Agent(name: "nina", emoji: "🔬", role: "checker", model: nil, sessionID: nil)]
    }

    func testSuggestionsMatchDisplayNames() {
        // A display whose first word ISN'T the handle — the case only display
        // matching can serve ("@Maxi" shares nothing with handle "bruno").
        var agents = team()
        agents[0].displayName = "Maximilian Writer"
        let hits = Mentions.suggestions(draft: "hey @Maxi", agents: agents, thread: "nina")
        XCTAssertEqual(hits.map(\.name), ["bruno"], "display prefix (case-insensitive) matches")
    }

    func testCompletionStillInsertsTheHandle() {
        let agents = team()
        let done = Mentions.complete(draft: "@Brun", with: agents[0], ifFragment: "brun")
        XCTAssertEqual(done, "@bruno ", "the handle is the address — display is for eyes")
    }

    func testRelayResolvesHandleAndDisplayName() throws {
        let agents = team()
        let byHandle = try XCTUnwrap(Mentions.resolveRelay(text: "@bruno check this", agents: agents))
        XCTAssertEqual(byHandle.target.name, "bruno")
        XCTAssertEqual(byHandle.question, "check this")
        let byDisplay = try XCTUnwrap(Mentions.resolveRelay(
            text: "@Bruno the Writer check this too", agents: agents))
        XCTAssertEqual(byDisplay.target.name, "bruno", "multi-word display name resolves")
        XCTAssertEqual(byDisplay.question, "check this too",
                       "LONGEST match wins — the display span beats the handle's first-word span")
        // "@Bruno the Writer" with nothing after it: the display branch needs a
        // question, so the HANDLE branch resolves it — documented ambiguity.
        let bare = try XCTUnwrap(Mentions.resolveRelay(text: "@Bruno the Writer", agents: agents))
        XCTAssertEqual(bare.question, "the Writer")
        XCTAssertNil(Mentions.resolveRelay(text: "@ghost hello", agents: agents))
    }

    func testLongestDisplayWinsOverShadowingPrefix() throws {
        var agents = team()
        agents.append(Agent(name: "bruno2", emoji: "🖋", role: "writer2", model: nil,
                            sessionID: nil, displayName: "Bruno"))
        let r = try XCTUnwrap(Mentions.resolveRelay(
            text: "@Bruno the Writer go", agents: agents))
        XCTAssertEqual(r.target.name, "bruno", "longest display match wins — 'Bruno' must not shadow 'Bruno the Writer'")
    }
}
