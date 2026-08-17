import XCTest
@testable import AgencyKit

final class RelayDirectiveTests: XCTestCase {
    func testParsesSingleDirective() {
        let reply = """
        Alfredo: Research done, note written to the vault.

        RELAY @annoyinglibrarian: Please review vault/q3-market-review.md and pass it on with your source research to Bruno.
        """
        XCTAssertEqual(RelayDirective.parse(reply), [
            RelayDirective(target: "annoyinglibrarian",
                           message: "Please review vault/q3-market-review.md and pass it on with your source research to Bruno."),
        ])
    }

    func testParsesMultipleRecipients() {
        let reply = "Done.\nRELAY @bruno: draft is ready\nRELAY @nina: please fact-check the draft"
        XCTAssertEqual(RelayDirective.parse(reply).map(\.target), ["bruno", "nina"])
    }

    func testTargetIsLowercasedLikeTheRoster() {
        let d = RelayDirective.parse("RELAY @AnnoyingLibrarian: hello")
        XCTAssertEqual(d.first?.target, "annoyinglibrarian")
    }

    func testProseAboutRelayingDoesNotTrigger() {
        XCTAssertEqual(RelayDirective.parse("I could not RELAY @bruno: the tools were missing, sorry."), [],
                       "keyword must be line-initial")
        XCTAssertEqual(RelayDirective.parse("the relay @bruno: pattern is neat"), [])
    }

    func testIndentedDirectiveStillParses() {
        XCTAssertEqual(RelayDirective.parse("  RELAY @nina: check this").count, 1)
    }

    func testMalformedDirectivesIgnored() {
        XCTAssertEqual(RelayDirective.parse("RELAY @: no name"), [])
        XCTAssertEqual(RelayDirective.parse("RELAY @bruno no colon"), [])
        XCTAssertEqual(RelayDirective.parse("RELAY @bruno:"), [], "empty message")
        XCTAssertEqual(RelayDirective.parse("RELAY @bru no: spaced name"), [])
    }

    /// Reviewer #5 Critical 2: an agent EXPLAINING the format in a code block
    /// was firing a real relay — fenced lines must be inert.
    func testFencedDirectiveDoesNotFire() {
        let reply = """
        Alfredo: here is how it works:

        ```
        RELAY @bruno: your message here
        ```
        That's the format.
        """
        XCTAssertEqual(RelayDirective.parse(reply), [])
    }

    func testDirectiveAfterAClosedFenceStillFires() {
        let reply = """
        ```
        example: RELAY @nina: not this one
        ```
        RELAY @bruno: this one is real
        """
        XCTAssertEqual(RelayDirective.parse(reply),
                       [RelayDirective(target: "bruno", message: "this one is real")])
    }

    // MARK: multi-line bodies (live truncation 2026-08-13)

    /// THE regression. An agent relayed an outbound message to a courier
    /// teammate; the old
    /// line-based parser delivered only the line ending "Exact text:" and
    /// silently dropped the message itself. Hermes received an instruction with
    /// its payload deleted and no warning that anything was missing.
    func testDirectiveCarriesItsWholeBlockNotJustTheFirstLine() {
        let reply = """
        Riker: Got it — the follow-up line (Bruno's pitch). Sending it on now.

        RELAY @teammate3: Lorenzo picked the follow-up joke. Exact text:

        "The rota says it's your turn to bring the coffee. Some of us think
        that's connected to the printer situation. Nobody's saying it out
        loud. I just did."
        """
        let d = RelayDirective.parse(reply)
        XCTAssertEqual(d.count, 1)
        XCTAssertTrue(d.first!.message.hasPrefix("Lorenzo picked the follow-up joke. Exact text:"))
        XCTAssertTrue(d.first!.message.contains("bring the coffee"),
                      "the payload must survive — truncating it silently is the bug")
        XCTAssertTrue(d.first!.message.hasSuffix("I just did.\""),
                      "including the last line")
    }

    func testStackedMultiLineDirectivesSplitAtTheNextRelay() {
        let reply = """
        RELAY @bruno: draft this:
        line one
        line two
        RELAY @nina: then fact-check it:
        check A
        """
        let d = RelayDirective.parse(reply)
        XCTAssertEqual(d.map(\.target), ["bruno", "nina"])
        XCTAssertEqual(d[0].message, "draft this:\nline one\nline two")
        XCTAssertEqual(d[1].message, "then fact-check it:\ncheck A")
    }

    /// The escape hatch for a reply that continues talking to Lorenzo AFTER a
    /// relay — without it, trailing prose is absorbed into the message.
    func testEndRelayTerminatesTheBlock() {
        let reply = """
        RELAY @bruno: send this along
        with this second line
        END RELAY

        Riker: dispatched — I'll report back when Bruno answers.
        """
        let d = RelayDirective.parse(reply)
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d[0].message, "send this along\nwith this second line")
        XCTAssertFalse(d[0].message.contains("dispatched"),
                       "END RELAY keeps Lorenzo-facing prose out of a teammate's message")
    }

    /// Agents quote drafts in code blocks; a fence INSIDE a body is content,
    /// and a RELAY line inside that fence must not split the block.
    func testFencedContentInsideABodyIsKeptAndDoesNotSplit() {
        let reply = """
        RELAY @teammate3: send exactly this:
        ```
        Hello — RELAY @nina: this is quoted text, not a directive
        ```
        Nothing after the quote.
        """
        let d = RelayDirective.parse(reply)
        XCTAssertEqual(d.count, 1, "the fenced RELAY must not open a second directive")
        XCTAssertEqual(d[0].target, "teammate3")
        XCTAssertTrue(d[0].message.contains("this is quoted text"), "fenced body is preserved")
        XCTAssertTrue(d[0].message.contains("Nothing after the quote."))
    }

    /// Review finding I-6: a SECOND directive whose handle is malformed
    /// ("@annoying librarian" — a space) used to be appended verbatim into the
    /// FIRST teammate's body. Bruno received AnnoyingLibrarian's message, the
    /// real recipient received nothing, and nobody was told. Worse than the old
    /// parser, which merely ignored the line.
    func testAMalformedSecondHeaderNeverLandsInTheFirstTeammatesMessage() {
        let d = RelayDirective.parse("""
        RELAY @bruno: draft the intro
        RELAY @annoying librarian: check the sources
        """)
        XCTAssertEqual(d.count, 1, "the malformed header addresses nobody")
        XCTAssertEqual(d[0].target, "bruno")
        XCTAssertEqual(d[0].message, "draft the intro",
                       "the other teammate's message must NOT be delivered to Bruno")
        XCTAssertFalse(d[0].message.contains("check the sources"))
    }

    /// Pinned, not accidental (review finding I-5): without `END RELAY`,
    /// trailing prose IS delivered to the teammate. Losing the payload is the
    /// far worse failure, so absorption is the deliberate trade — but it is a
    /// tested property, and the persona teaches the escape hatch.
    func testTrailingProseIsAbsorbedWhenEndRelayIsOmitted() {
        let d = RelayDirective.parse("""
        RELAY @bruno: do the thing

        Riker: dispatched.
        """)
        XCTAssertEqual(d.count, 1)
        XCTAssertTrue(d[0].message.contains("Riker: dispatched."),
                      "documented trade-off — END RELAY is the way to avoid it")
    }

    /// Reviewer #5 Important 3: hyphens/underscores are legal agent names
    /// (AgentStore.isValidName) — the parser must reach them.
    func testHyphenAndUnderscoreTargetsParse() {
        XCTAssertEqual(RelayDirective.parse("RELAY @fact-checker: review this").first?.target,
                       "fact-checker")
        XCTAssertEqual(RelayDirective.parse("RELAY @beta_2: ping").first?.target, "beta_2")
    }
}
