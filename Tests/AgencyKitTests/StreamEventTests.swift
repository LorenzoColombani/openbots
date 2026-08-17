import XCTest
@testable import AgencyKit

final class StreamEventTests: XCTestCase {
    func testParsesInitSessionID() {
        let line = #"{"type":"system","subtype":"init","session_id":"bf68fc58-1111"}"#
        XCTAssertEqual(StreamEvent.parse(line: line), .sessionStarted("bf68fc58-1111"))
    }
    func testParsesTextDelta() {
        let line = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Alfredo:"}}}"#
        XCTAssertEqual(StreamEvent.parse(line: line), .textDelta("Alfredo:"))
    }
    func testParsesThinkingDelta() {
        let line = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":""}}}"#
        XCTAssertEqual(StreamEvent.parse(line: line), .thinkingDelta(""))
    }
    func testParsesResult() {
        let line = #"{"type":"result","subtype":"success","result":"OK","session_id":"abc-1"}"#
        XCTAssertEqual(StreamEvent.parse(line: line), .resultText("OK", sessionID: "abc-1"))
    }
    func testBlankLineIsNil_UnknownIsIgnored() {
        XCTAssertNil(StreamEvent.parse(line: "  "))
        XCTAssertEqual(StreamEvent.parse(line: #"{"type":"assistant","message":{}}"#), .ignored)
    }

    /// Real capture from a live `claude -p --resume <bogus>` (2026-08-12): the
    /// error result has NO "result" string — it must surface, not become an
    /// empty bubble (review #1 minor, promoted).
    func testErrorResultSurfacesInsteadOfIgnored() {
        let line = #"{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"x","errors":["No conversation found with session ID: x"]}"#
        XCTAssertEqual(StreamEvent.parse(line: line),
                       .runError("No conversation found with session ID: x"))
    }

    /// Non-init system events may carry a session_id (compact boundaries) and
    /// must not re-trigger sessionStarted.
    func testNonInitSystemEventIgnored() {
        let line = #"{"type":"system","subtype":"compact_boundary","session_id":"abc"}"#
        XCTAssertEqual(StreamEvent.parse(line: line), .ignored)
    }

    /// Shaped like a live `claude -p` capture: the CLI emits one of these on
    /// EVERY message once the account is in a warning state — the payload is
    /// structured, and the old substring filter turned it into a bubble per
    /// send.
    func testParsesRateLimitEventStructured() {
        let line = #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","resetsAt":1755000000,"rateLimitType":"seven_day","utilization":0.75,"isUsingOverage":false},"uuid":"00000000","session_id":"00000000"}"#
        let expected = RateLimitInfo(status: "allowed_warning", kind: "seven_day",
                                     utilization: 0.75, resetsAt: 1755000000)
        XCTAssertEqual(StreamEvent.parse(line: line), .rateLimit(expected))
        XCTAssertTrue(expected.isWarning)
    }

    func testRoutineAllowedRateLimitIsNotAWarning() {
        let line = #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","rateLimitType":"five_hour"}}"#
        guard case .rateLimit(let info)? = StreamEvent.parse(line: line) else {
            return XCTFail("expected a rateLimit event")
        }
        XCTAssertFalse(info.isWarning)
    }

    func testMalformedRateLimitEventIgnored() {
        let line = #"{"type":"rate_limit_event","uuid":"x"}"#
        XCTAssertEqual(StreamEvent.parse(line: line), .ignored)
    }

    func testSameWarningStateSharesADedupeKey() {
        let a = RateLimitInfo(status: "allowed_warning", kind: "seven_day",
                              utilization: 0.75, resetsAt: 1755000000)
        let b = RateLimitInfo(status: "allowed_warning", kind: "seven_day",
                              utilization: 0.61, resetsAt: 1755000000)   // usage crept up
        XCTAssertEqual(a.dedupeKey, b.dedupeKey, "same window+status = same warning, not news")
        let rejected = RateLimitInfo(status: "rejected", kind: "seven_day",
                                     utilization: 1.0, resetsAt: 1755000000)
        XCTAssertNotEqual(a.dedupeKey, rejected.dedupeKey)
    }

    /// The gate is what turns "an event per message" into "a bubble per state
    /// change" — the live complaint was one warning bubble on EVERY send.
    func testRateLimitGateAnnouncesEachStateOnce() {
        let gate = RateLimitGate()
        let warning = RateLimitInfo(status: "allowed_warning", kind: "seven_day",
                                    utilization: 0.75, resetsAt: 1755000000)
        XCTAssertTrue(gate.shouldAnnounce(warning), "first sighting is news")
        XCTAssertFalse(gate.shouldAnnounce(warning), "same state again is not")
        let crept = RateLimitInfo(status: "allowed_warning", kind: "seven_day",
                                  utilization: 0.71, resetsAt: 1755000000)
        XCTAssertFalse(gate.shouldAnnounce(crept), "utilization creep is the same warning")
        let rejected = RateLimitInfo(status: "rejected", kind: "seven_day",
                                     utilization: 1.0, resetsAt: 1755000000)
        XCTAssertTrue(gate.shouldAnnounce(rejected), "escalation IS news")
    }

    func testRateLimitGateResetsWhenStateClears() {
        let gate = RateLimitGate()
        let warning = RateLimitInfo(status: "allowed_warning", kind: "five_hour",
                                    utilization: 0.9, resetsAt: 100)
        XCTAssertTrue(gate.shouldAnnounce(warning))
        let allowed = RateLimitInfo(status: "allowed", kind: "five_hour",
                                    utilization: 0.1, resetsAt: 200)
        XCTAssertFalse(gate.shouldAnnounce(allowed), "healthy state is never announced")
        XCTAssertTrue(gate.shouldAnnounce(warning), "re-entering warning after clear is news")
    }

    /// Reviewer #5 Important 6: the CLI reports whichever window currently
    /// binds — a routine five_hour "allowed" must not wipe the standing
    /// seven_day warning and re-announce it.
    func testRateLimitGateTracksWindowsIndependently() {
        let gate = RateLimitGate()
        let sevenDay = RateLimitInfo(status: "allowed_warning", kind: "seven_day",
                                     utilization: 0.55, resetsAt: 1755000000)
        let fiveHourOK = RateLimitInfo(status: "allowed", kind: "five_hour",
                                       utilization: 0.1, resetsAt: 500)
        XCTAssertTrue(gate.shouldAnnounce(sevenDay), "first sighting is news")
        XCTAssertFalse(gate.shouldAnnounce(fiveHourOK), "other window healthy — silent")
        XCTAssertFalse(gate.shouldAnnounce(sevenDay),
                       "the healthy five_hour ping must NOT resurrect the seven_day warning")
        let fiveHourWarn = RateLimitInfo(status: "allowed_warning", kind: "five_hour",
                                         utilization: 0.95, resetsAt: 600)
        XCTAssertTrue(gate.shouldAnnounce(fiveHourWarn), "a NEW window's warning is separate news")
        XCTAssertFalse(gate.shouldAnnounce(sevenDay), "…and still doesn't re-announce the old one")
    }

    /// message_start marks a new assistant message inside the agentic loop —
    /// the streaming preview resets there (his call: no accumulated narration).
    func testParsesMessageBoundary() {
        let line = #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_1","role":"assistant"}}}"#
        XCTAssertEqual(StreamEvent.parse(line: line), .messageBoundary)
    }

    func testOtherStreamEventsStillIgnored() {
        let line = #"{"type":"stream_event","event":{"type":"content_block_start","index":0}}"#
        XCTAssertEqual(StreamEvent.parse(line: line), .ignored)
    }
}

/// Visibility round (his asks 2026-08-13): thinking text + tool activity.
extension StreamEventTests {
    func testThinkingDeltaCarriesTheText() {
        let line = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"pondering the vault"}}}"#
        XCTAssertEqual(StreamEvent.parse(line: line), .thinkingDelta("pondering the vault"))
    }

    func testAssistantToolUseBecomesActivity() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"vault/notes.md"}},{"type":"text","text":"…"}]}}"#
        XCTAssertEqual(StreamEvent.parse(line: line), .toolActivity("Read vault/notes.md"))
        let grep = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Grep","input":{"pattern":"needle"}}]}}"#
        XCTAssertEqual(StreamEvent.parse(line: grep), .toolActivity("Grep \"needle\""))
        let plain = #"{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}"#
        XCTAssertEqual(StreamEvent.parse(line: plain), .ignored, "text-only assistant messages stay quiet")
    }
}
