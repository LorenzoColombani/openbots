import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsRuntime

@Test("Split-byte stream emits only correlated metadata, bounded text and successful final reply")
func claudeTextStreamSuccess() throws {
    let request = try textOnlyTestRequest()
    var stream = ClaudeTextOnlyStream(request: request)
    var events: [ClaudeTextOnlyEvent] = []
    let data = try textOnlyTestInit(request) + textOnlyTestReplay(request)
        + textOnlyTestDelta(request, text: "Hello ") + textOnlyTestDelta(request, text: "back") + textOnlyTestResult(request)
    for byte in data { events += try stream.consume(Data([byte])) }
    #expect(events.first == .initialized(sessionID: request.sessionID, actualModel: "claude-sonnet-5"))
    #expect(events.contains(.inputAcknowledged(messageID: request.messageID)))
    #expect(events.contains(.textSnapshot("Hello back")))
    #expect(stream.finish(exitCode: 0) == .success(.init(sessionID: request.sessionID, actualModel: "claude-sonnet-5", text: "Hello back", confirmedActualModel: "claude-sonnet-5")))
    #expect(stream.finish(exitCode: 1) == .failed(.processFailed))
}

@Test("Unsafe or contradictory initialization fails closed")
func claudeTextStreamRejectsInitialization() throws {
    let request = try textOnlyTestRequest()
    let overrides: [[String: Any]] = [
        ["tools": ["Read"]], ["mcp_servers": [["name": "external"]]], ["plugins": [["name": "plugin"]]],
        ["plugin_errors": [["message": "discard"]]], ["mcp_server_errors": [["message": "discard"]]],
        ["apiKeySource": "user"], ["permissionMode": "acceptEdits"], ["model": "claude-opus-4-6"],
        ["model": "claude-sonnet-5[1m]"], ["session_id": "wrong"], ["tools": NSNull()]
    ]
    for override in overrides {
        var stream = ClaudeTextOnlyStream(request: request)
        #expect(throws: ClaudeTextOnlyFailure.unsafeInitialization) { try stream.consume(textOnlyTestInit(request, override: override)) }
    }
}

@Test("Final success requires init, exact replay, actual final text and a successful process")
func claudeTextStreamRequiresCompleteProof() throws {
    let request = try textOnlyTestRequest()
    var missingReplay = ClaudeTextOnlyStream(request: request)
    _ = try missingReplay.consume(textOnlyTestInit(request) + textOnlyTestResult(request))
    #expect(missingReplay.finish(exitCode: 0) == .failed(.invalidStream))
    var missingFinal = ClaudeTextOnlyStream(request: request)
    _ = try missingFinal.consume(textOnlyTestInit(request) + textOnlyTestReplay(request) + textOnlyTestDelta(request, text: "Partial"))
    #expect(missingFinal.finish(exitCode: 0) == .failed(.invalidStream))
    var missingInit = ClaudeTextOnlyStream(request: request)
    #expect(throws: ClaudeTextOnlyFailure.invalidStream) { try missingInit.consume(textOnlyTestResult(request)) }
}

@Test("Wrong replay UUID or text is not an acknowledgment")
func claudeTextStreamRejectsMismatchedReplay() throws {
    let request = try textOnlyTestRequest()
    var stream = ClaudeTextOnlyStream(request: request)
    let wrong = try textOnlyTestRequest(text: "A different prompt")
    #expect(throws: ClaudeTextOnlyFailure.invalidStream) { try stream.consume(textOnlyTestReplay(wrong)) }
    var second = ClaudeTextOnlyStream(request: request)
    var replay = try #require(JSONSerialization.jsonObject(with: textOnlyTestReplay(request)) as? [String: Any])
    replay["uuid"] = UUID().uuidString
    #expect(throws: ClaudeTextOnlyFailure.invalidStream) { try second.consume(textOnlyTestLine(replay)) }
}

@Test("Replay proof compares exact UTF8 rather than canonically equivalent Unicode")
func claudeTextStreamRejectsNormalizedReplay() throws {
    let decomposed = "Cafe\u{301}"
    let composed = "Café"
    #expect(decomposed == composed)
    #expect(!decomposed.utf8.elementsEqual(composed.utf8))
    let request = try textOnlyTestRequest(text: decomposed)
    let changed = try textOnlyTestRequest(text: composed)
    var stream = ClaudeTextOnlyStream(request: request)
    var events: [ClaudeTextOnlyEvent] = []
    #expect(throws: ClaudeTextOnlyRejection(failure: .invalidStream, code: .replayTextMismatch)) {
        try stream.consume(textOnlyTestReplay(changed)) { events.append($0) }
    }
    #expect(events.isEmpty)
    var exact = ClaudeTextOnlyStream(request: request)
    try exact.consume(textOnlyTestReplay(request)) { events.append($0) }
    #expect(events == [.inputAcknowledged(messageID: request.messageID)])
}

@Test("A single read preserves validated init, acknowledgment and partial before a terminal error")
func claudeTextStreamPreservesPrefixOnError() throws {
    let request = try textOnlyTestRequest()
    let chunk = try textOnlyTestInit(request) + textOnlyTestReplay(request)
        + textOnlyTestDelta(request, text: "Verified partial")
        + textOnlyTestResult(request, override: ["is_error": true, "result": "Unvalidated provider diagnostic"])
    var stream = ClaudeTextOnlyStream(request: request)
    var events: [ClaudeTextOnlyEvent] = []
    #expect(throws: ClaudeTextOnlyRejection(failure: .providerFailed, code: .providerFailure)) {
        try stream.consume(chunk) { events.append($0) }
    }
    #expect(events == [.initialized(sessionID: request.sessionID, actualModel: "claude-sonnet-5"),
                       .inputAcknowledged(messageID: request.messageID), .textSnapshot("Verified partial")])
    #expect(stream.finish(exitCode: 0) == .failed(.invalidStream))
}

@Test("A valid prefix remains delivered before a same-read malformed line or total-byte limit")
func claudeTextStreamPreservesPrefixOnProtocolLimits() throws {
    let request = try textOnlyTestRequest()
    let prefix = try textOnlyTestInit(request) + textOnlyTestReplay(request)
        + textOnlyTestDelta(request, text: "Verified partial")
    let suffixes = [Data("malformed\n".utf8), Data(repeating: 10, count: ClaudeTextOnlyStream.maximumOutputBytes)]
    for suffix in suffixes {
        var stream = ClaudeTextOnlyStream(request: request)
        var events: [ClaudeTextOnlyEvent] = []
        #expect(throws: (any Error).self) { try stream.consume(prefix + suffix) { events.append($0) } }
        #expect(events == [.initialized(sessionID: request.sessionID, actualModel: "claude-sonnet-5"),
                           .inputAcknowledged(messageID: request.messageID), .textSnapshot("Verified partial")])
    }
}

@Test("Error result carrying text never becomes a successful reply")
func claudeTextStreamRejectsProviderError() throws {
    let request = try textOnlyTestRequest()
    let overrides: [[String: Any]] = [["is_error": true], ["is_error": 0], ["subtype": "error_during_execution"],
                                     ["result": " "], ["permission_denials": [["tool_name": "Read"]]]]
    for override in overrides {
        var stream = ClaudeTextOnlyStream(request: request)
        _ = try stream.consume(textOnlyTestInit(request))
        #expect(throws: ClaudeTextOnlyFailure.providerFailed) { try stream.consume(textOnlyTestResult(request, override: override)) }
    }
    // The turn cap is an error result too, and never a reply; it is reported
    // as the cap it is rather than as a provider fault.
    var capped = ClaudeTextOnlyStream(request: request)
    _ = try capped.consume(textOnlyTestInit(request))
    #expect(throws: ClaudeTextOnlyFailure.turnLimitReached) {
        try capped.consume(textOnlyTestResult(request, override: ["subtype": "error_max_turns", "is_error": true]))
    }
    #expect(capped.finish(exitCode: 0) == .failed(.invalidStream))
}

@Test("Hook, control, tool and descendant events cannot enter the text stream")
func claudeTextStreamRejectsExecutionEvents() throws {
    let request = try textOnlyTestRequest()
    let prohibited: [[String: Any]] = [
        ["type": "system", "subtype": "hook_started"],
        ["type": "control_request", "request": ["subtype": "can_use_tool"]],
        ["type": "stream_event", "event": ["type": "content_block_start", "content_block": ["type": "tool_use", "name": "Bash"]]],
        ["type": "assistant", "message": ["role": "assistant", "model": "claude-sonnet-5", "content": [["type": "tool_use", "name": "Read"]]]],
        ["type": "assistant", "parent_tool_use_id": "nested", "message": ["role": "assistant", "model": "claude-sonnet-5", "content": []]]
    ]
    for var value in prohibited {
        var stream = ClaudeTextOnlyStream(request: request)
        _ = try stream.consume(textOnlyTestInit(request))
        value["session_id"] = request.sessionID.uuidString
        #expect(throws: (any Error).self) { try stream.consume(textOnlyTestLine(value)) }
    }
}

@Test("Flat correlated informational drift is bounded metadata and grants no reply authority")
func claudeTextStreamIgnoresReviewedInformationalFrames() throws {
    let request = try textOnlyTestRequest()
    var stream = ClaudeTextOnlyStream(request: request)
    let topLevel: [String: Any] = [
        "type": "telemetry_event", "session_id": request.sessionID.uuidString,
        "uuid": UUID().uuidString, "sequence": 1, "phase": "transport"
    ]
    let system: [String: Any] = [
        "type": "system", "subtype": "update_notice", "session_id": request.sessionID.uuidString,
        "uuid": UUID().uuidString, "version": "2.1.253", "available": true
    ]
    let statusVariant: [String: Any] = [
        "type": "status_notice", "session_id": request.sessionID.uuidString,
        "uuid": UUID().uuidString, "phase": "transport", "active": true
    ]
    let afterResult: [String: Any] = [
        "type": "diagnostic_metadata", "session_id": request.sessionID.uuidString,
        "uuid": UUID().uuidString, "level": "info", "sequence": 2
    ]
    let frames = try textOnlyTestLine(topLevel) + textOnlyTestLine(system) + textOnlyTestLine(statusVariant)
        + textOnlyTestInit(request) + textOnlyTestReplay(request) + textOnlyTestResult(request)
        + textOnlyTestLine(afterResult)
    #expect(try stream.consume(frames) == [
        .initialized(sessionID: request.sessionID, actualModel: "claude-sonnet-5"),
        .inputAcknowledged(messageID: request.messageID), .textSnapshot("Hello back")
    ])
    #expect(stream.ignoredInformationalEventCount == 4)
    #expect(stream.finish(exitCode: 0) == .success(.init(sessionID: request.sessionID,
        actualModel: "claude-sonnet-5", text: "Hello back", confirmedActualModel: "claude-sonnet-5")))
}

/// CLI 2.1.261+ streams a live thinking-token estimate during headless turns. The
/// job path accepted it; the text path once rejected it as an unexpected
/// system event and every text reply failed with the current CLI (2.1.263).
@Test("The CLI's thinking-token progress frames are bounded metadata inside a text turn and grant nothing")
func claudeTextStreamIgnoresThinkingTokenFrames() throws {
    let request = try textOnlyTestRequest()
    var stream = ClaudeTextOnlyStream(request: request)
    let thinking: [String: Any] = [
        "type": "system", "subtype": "thinking_tokens", "session_id": request.sessionID.uuidString,
        "uuid": UUID().uuidString, "estimated_tokens": 42, "estimated_tokens_delta": 42
    ]
    let frames = try textOnlyTestInit(request) + textOnlyTestLine(thinking) + textOnlyTestReplay(request)
        + textOnlyTestLine(thinking) + textOnlyTestDelta(request, text: "Hello") + textOnlyTestLine(thinking)
        + textOnlyTestResult(request)
    #expect(try stream.consume(frames) == [
        .initialized(sessionID: request.sessionID, actualModel: "claude-sonnet-5"),
        .inputAcknowledged(messageID: request.messageID), .textSnapshot("Hello"), .textSnapshot("Hello back")
    ])
    #expect(stream.ignoredInformationalEventCount == 0)
    #expect(stream.thinkingTokenFrameCount == 3)
    #expect(stream.finish(exitCode: 0) == .success(.init(sessionID: request.sessionID,
        actualModel: "claude-sonnet-5", text: "Hello back", confirmedActualModel: "claude-sonnet-5")))

    let session = request.sessionID.uuidString
    let prohibited: [[String: Any]] = [
        ["type": "system", "subtype": "thinking_tokens", "session_id": UUID().uuidString, "estimated_tokens": 1],
        ["type": "system", "subtype": "thinking_tokens", "estimated_tokens": 1],
        ["type": "system", "subtype": "thinking_tokens", "session_id": session, "estimated_tokens": ["nested": 1]],
        ["type": "system", "subtype": "thinking_tokens", "session_id": session, "text": "free text"],
        ["type": "system", "subtype": "thinking_tokens", "session_id": session, "tool_use_id": "tool-1"],
        ["type": "system", "subtype": "thinking_tokens", "session_id": session, "Estimated": 1],
        ["type": "system", "subtype": "thinking_tokens", "session_id": session, "parent_tool_use_id": "tool-1"]
    ]
    for value in prohibited {
        var rejecting = ClaudeTextOnlyStream(request: request)
        #expect(throws: (any Error).self) {
            try rejecting.consume(textOnlyTestInit(request) + textOnlyTestLine(value)) { _ in }
        }
    }
    // Before initialization the frame proves nothing and is refused.
    var early = ClaudeTextOnlyStream(request: request)
    #expect(throws: (any Error).self) { try early.consume(textOnlyTestLine(thinking)) { _ in } }
}

@Test("Unknown informational labels still reject uncorrelated, nested, sensitive and reserved shapes")
func claudeTextStreamRejectsUnsafeInformationalFrames() throws {
    let request = try textOnlyTestRequest()
    let prohibited: [[String: Any]] = [
        ["type": "telemetry_event", "session_id": UUID().uuidString, "sequence": 1],
        ["type": "telemetry_event", "sequence": 1],
        ["type": "telemetry_event", "subtype": "control_request",
            "session_id": request.sessionID.uuidString, "sequence": 1],
        ["type": "telemetry_event", "session-id": request.sessionID.uuidString, "sequence": 1],
        ["type": "telemetry_event", "session_id": request.sessionID.uuidString,
            "Type": "control_request", "sequence": 1],
        ["type": "telemetry_event", "session_id": request.sessionID.uuidString,
            "Sub-Type": "permission_notice", "sequence": 1],
        ["type": "telemetry_event", "session_id": request.sessionID.uuidString,
            "parent_tool_use_id": NSNull(), "sequence": 1],
        ["type": "telemetry_event", "session_id": request.sessionID.uuidString,
            "payload": "synthetic private payload"],
        ["type": "telemetry_event", "session_id": request.sessionID.uuidString,
            "private_key": "synthetic private payload"],
        ["type": "progress_metadata", "session_id": request.sessionID.uuidString,
            "metrics": ["stage": 1]],
        ["type": "tool_telemetry", "session_id": request.sessionID.uuidString, "sequence": 1],
        ["type": "result_metadata", "session_id": request.sessionID.uuidString, "sequence": 1],
        ["type": "api_key_notice", "session_id": request.sessionID.uuidString, "sequence": 1],
        ["type": "diagnostic_notice", "session_id": request.sessionID.uuidString,
            "command": "synthetic executable input"],
        ["type": "telemetry_event", "session_id": request.sessionID.uuidString, "capability": "tools"],
        ["type": "telemetry_event", "session_id": request.sessionID.uuidString, "allow": true],
        ["type": "telemetry_event", "session_id": request.sessionID.uuidString, "grant": "filesystem"],
        ["type": "telemetry_event", "session_id": request.sessionID.uuidString, "kind": "control"],
        ["type": "telemetry_event", "session_id": request.sessionID.uuidString, "privilege": "write"],
        ["type": "telemetry_event", "session_id": request.sessionID.uuidString,
            "category": "control_request", "source": "auth", "phase": "tool_use"],
        ["type": "system", "subtype": "permission_notice", "session_id": request.sessionID.uuidString]
    ]
    for value in prohibited {
        var stream = ClaudeTextOnlyStream(request: request)
        #expect(throws: (any Error).self) {
            try stream.consume(textOnlyTestLine(value)) { _ in Issue.record("Unsafe informational frame escaped") }
        }
        #expect(stream.ignoredInformationalEventCount == 0)
    }
}

@Test("Unknown informational-frame tolerance has a finite budget")
func claudeTextStreamBoundsInformationalFrames() throws {
    let request = try textOnlyTestRequest()
    var stream = ClaudeTextOnlyStream(request: request)
    for sequence in 0..<ClaudeTextOnlyStream.maximumIgnoredInformationalEvents {
        let frame: [String: Any] = [
            "type": "progress_notice", "session_id": request.sessionID.uuidString,
            "uuid": UUID().uuidString, "sequence": sequence
        ]
        #expect(try stream.consume(textOnlyTestLine(frame)).isEmpty)
    }
    #expect(stream.ignoredInformationalEventCount == ClaudeTextOnlyStream.maximumIgnoredInformationalEvents)
    let overflow: [String: Any] = [
        "type": "progress_notice", "session_id": request.sessionID.uuidString,
        "uuid": UUID().uuidString, "sequence": ClaudeTextOnlyStream.maximumIgnoredInformationalEvents
    ]
    #expect(throws: ClaudeTextOnlyRejection(failure: .invalidStream, code: .unexpectedEvent)) {
        try stream.consume(textOnlyTestLine(overflow)) { _ in Issue.record("Over-budget frame escaped") }
    }
}

@Test("Thinking and normal rate metadata are discarded and assistant snapshots do not duplicate text")
func claudeTextStreamDiscardsNontext() throws {
    let request = try textOnlyTestRequest()
    var stream = ClaudeTextOnlyStream(request: request)
    _ = try stream.consume(textOnlyTestInit(request))
    let ignored: [[String: Any]] = [
        ["type": "stream_event", "event": ["type": "content_block_delta", "delta": ["type": "thinking_delta", "thinking": "private"]]],
        ["type": "assistant", "message": ["role": "assistant", "model": "claude-sonnet-5", "content": [["type": "text", "text": "Hello back"]]]],
        ["type": "rate_limit_event", "rate_limit_info": ["status": "allowed_warning", "resetsAt": 99]]
    ]
    for var value in ignored {
        value["session_id"] = request.sessionID.uuidString
        #expect(try stream.consume(textOnlyTestLine(value)).isEmpty)
    }
}

@Test("Malformed, deeply nested, truncated and oversized streams are bounded")
func claudeTextStreamBounds() throws {
    let request = try textOnlyTestRequest()
    var malformed = ClaudeTextOnlyStream(request: request)
    #expect(throws: ClaudeTextOnlyFailure.invalidStream) { try malformed.consume(Data("not json\n".utf8)) }
    var nested = ClaudeTextOnlyStream(request: request)
    let nesting = "{\"type\":\"user\",\"x\":" + String(repeating: "[", count: 25) + "0" + String(repeating: "]", count: 25) + "}\n"
    #expect(throws: ClaudeTextOnlyFailure.invalidStream) { try nested.consume(Data(nesting.utf8)) }
    var oversized = ClaudeTextOnlyStream(request: request)
    #expect(throws: ClaudeTextOnlyFailure.outputLimitExceeded) {
        try oversized.consume(Data(repeating: 120, count: ClaudeTextOnlyStream.maximumLineBytes + 1))
    }
    var total = ClaudeTextOnlyStream(request: request)
    #expect(throws: ClaudeTextOnlyFailure.outputLimitExceeded) {
        try total.consume(Data(repeating: 10, count: ClaudeTextOnlyStream.maximumOutputBytes + 1))
    }
    var truncated = ClaudeTextOnlyStream(request: request)
    _ = try truncated.consume(textOnlyTestInit(request) + textOnlyTestReplay(request))
    var final = try textOnlyTestResult(request); final.removeLast()
    _ = try truncated.consume(final)
    #expect(truncated.finish(exitCode: 0) == .failed(.invalidStream))
}

@Test("Each admitted model must initialize as its exact resolved model",
      arguments: ClaudeTextOnlyRequest.supportedModels.sorted())
func claudeTextStreamRequestedModelProof(_ model: String) throws {
    let request = try textOnlyTestRequest(model: model)
    var stream = ClaudeTextOnlyStream(request: request)
    _ = try stream.consume(textOnlyTestInit(request) + textOnlyTestReplay(request) + textOnlyTestResult(request))
    #expect(stream.finish(exitCode: 0) == .success(.init(sessionID: request.sessionID,
        actualModel: request.expectedResolvedModel, text: "Hello back", confirmedActualModel: request.expectedResolvedModel)))
    var mismatch = ClaudeTextOnlyStream(request: request)
    let other = request.expectedResolvedModel == "claude-opus-5" ? "claude-sonnet-5" : "claude-opus-5"
    #expect(throws: ClaudeTextOnlyRejection(failure: .unsafeInitialization, code: .initializationModelInvalid)) {
        try mismatch.consume(textOnlyTestInit(request, override: ["model": other])) { _ in Issue.record("Mismatched init escaped") }
    }
}

@Test("Documented long-context suffix normalization preserves the exact pinned model identity",
      arguments: ["claude-opus-4-6", "claude-sonnet-4-6"])
func claudeTextStreamLongContextModelIdentity(_ model: String) throws {
    let request = try textOnlyTestRequest(model: model, contextWindow: "long")
    for observed in [model, model + "[1m]"] {
        var stream = ClaudeTextOnlyStream(request: request)
        _ = try stream.consume(textOnlyTestInit(request, override: ["model": observed]) + textOnlyTestReplay(request)
            + textOnlyTestResult(request, override: ["modelUsage": [observed: [:]]]))
        #expect(stream.finish(exitCode: 0) == .success(.init(sessionID: request.sessionID,
            actualModel: observed, text: "Hello back", confirmedActualModel: observed)))
    }
    var different = ClaudeTextOnlyStream(request: request)
    #expect(throws: ClaudeTextOnlyFailure.unsafeInitialization) {
        try different.consume(textOnlyTestInit(request, override: ["model": "claude-sonnet-5"]))
    }
}

@Test("Successful result metadata reports an actual-model mismatch without rewriting the requested choice")
func claudeTextStreamReportsActualModelChange() throws {
    let request = try textOnlyTestRequest()
    var stream = ClaudeTextOnlyStream(request: request)
    _ = try stream.consume(textOnlyTestInit(request) + textOnlyTestReplay(request)
        + textOnlyTestResult(request, override: ["modelUsage": ["claude-haiku-4-5-20251001": [:]]]))
    #expect(stream.finish(exitCode: 0) == .success(.init(sessionID: request.sessionID,
        actualModel: "claude-haiku-4-5-20251001", text: "Hello back", confirmedActualModel: "claude-haiku-4-5-20251001")))
    #expect(request.model == "sonnet")
}

@Test("Missing result model usage never turns initialization into confirmed model evidence")
func claudeTextStreamMissingUsageRemainsUnconfirmed() throws {
    let request = try textOnlyTestRequest()
    var root = try #require(JSONSerialization.jsonObject(with: textOnlyTestResult(request)) as? [String: Any])
    root.removeValue(forKey: "modelUsage")
    var stream = ClaudeTextOnlyStream(request: request)
    _ = try stream.consume(textOnlyTestInit(request) + textOnlyTestReplay(request) + textOnlyTestLine(root))
    #expect(stream.finish(exitCode: 0) == .success(.init(sessionID: request.sessionID,
        actualModel: "claude-sonnet-5", text: "Hello back", confirmedActualModel: nil)))
}

@Test("Only admitted startup and successful result models supply durable evidence, not extra provider fields")
func claudeTextStreamExecutionEvidenceIsLimited() throws {
    let request = try textOnlyTestRequest(model: "claude-sonnet-5", effort: "low", contextWindow: "standard")
    var stream = ClaudeTextOnlyStream(request: request)
    let events = try stream.consume(textOnlyTestInit(request, override: ["effort": "max", "contextWindow": 1_000_000])
        + textOnlyTestReplay(request)
        + textOnlyTestResult(request, override: ["modelUsage": ["claude-opus-5": ["contextWindow": 1_000_000]], "effort": "max"]))
    guard let first = events.first, case let .initialized(sessionID, initializedModel) = first,
          case let .success(reply) = stream.finish(exitCode: 0) else {
        Issue.record("Valid model observations were lost"); return
    }
    let evidence = ClaudeExecutionEvidence(request: request.executionRequest,
        initializedModel: initializedModel, resultModel: reply.confirmedActualModel)
    #expect(sessionID == evidence.request.sessionID)
    #expect(try evidence.validated().modelStatus == .resultDiffers)
    #expect(evidence.request.selection.effort == "low")
    #expect(evidence.request.selection.contextWindow == "standard")
    #expect(evidence.resultModel == "claude-opus-5")
    #expect(!String(decoding: try JSONEncoder().encode(evidence), as: UTF8.self).contains("1000000"))
}

@Test("Unknown, malformed, ambiguous or response-inconsistent final model metadata cannot confirm a model")
func claudeTextStreamRejectsInvalidModelUsage() throws {
    let request = try textOnlyTestRequest()
    let invalid: [Any] = [NSNull(), "provider diagnostic", [:] as [String: Any],
        ["claude-unreviewed": [:]], ["claude-sonnet-5": "not usage"],
        ["claude-sonnet-5": [:], "claude-opus-5": [:]]]
    for value in invalid {
        var stream = ClaudeTextOnlyStream(request: request)
        _ = try stream.consume(textOnlyTestInit(request) + textOnlyTestReplay(request))
        #expect(throws: ClaudeTextOnlyRejection(failure: .unsafeInitialization, code: .finalModelMismatch)) {
            try stream.consume(textOnlyTestResult(request, override: ["modelUsage": value])) { _ in Issue.record("Invalid result escaped") }
        }
    }
    var contradictory = ClaudeTextOnlyStream(request: request)
    _ = try contradictory.consume(textOnlyTestInit(request) + textOnlyTestReplay(request)
        + textOnlyTestLine(["type": "assistant", "session_id": request.sessionID.uuidString,
            "message": ["role": "assistant", "model": "claude-sonnet-5", "content": []]]))
    #expect(throws: ClaudeTextOnlyFailure.unsafeInitialization) {
        try contradictory.consume(textOnlyTestResult(request, override: ["modelUsage": ["claude-opus-5": [:]]]))
    }
}

@Test("All official CLI status variants preserve proof and accept both exact replay text representations")
func claudeTextStreamDocumentedStatusAndReplay() throws {
    let request = try textOnlyTestRequest(text: "Exact Cafe\u{301}\n😀")
    for stringContent in [false, true] {
        var stream = ClaudeTextOnlyStream(request: request)
        let status: [String: Any] = ["type": "system", "subtype": "status", "status": NSNull(),
            "uuid": UUID().uuidString, "session_id": request.sessionID.uuidString]
        #expect(try stream.consume(textOnlyTestLine(status)).isEmpty)
        var withoutEventID = status
        withoutEventID.removeValue(forKey: "uuid")
        #expect(try stream.consume(textOnlyTestLine(withoutEventID)).isEmpty)
        #expect(stream.finish(exitCode: 0) == .failed(.invalidStream))
        _ = try stream.consume(textOnlyTestInit(request))
        let statusValues: [Any] = [NSNull(), "compacting", "requesting"]
        for statusValue in statusValues {
            var metadata = status
            metadata["status"] = statusValue
            metadata["permissionMode"] = "dontAsk"
            #expect(try stream.consume(textOnlyTestLine(metadata)).isEmpty)
        }
        #expect(try stream.consume(textOnlyTestReplay(request, stringContent: stringContent)) == [.inputAcknowledged(messageID: request.messageID)])
        _ = try stream.consume(textOnlyTestResult(request))
        #expect(stream.finish(exitCode: 0) == .success(.init(sessionID: request.sessionID, actualModel: "claude-sonnet-5", text: "Hello back", confirmedActualModel: "claude-sonnet-5")))
    }
}

@Test("Status metadata cannot change session or permission mode, or pretend to initialize")
func claudeTextStreamRejectsUnsafeStatus() throws {
    let request = try textOnlyTestRequest()
    let overrides: [([String: Any], ClaudeTextOnlyRejection)] = [
        (["status": "unknown"], .init(failure: .invalidStream, code: .invalidStatusMetadata)),
        (["status": false], .init(failure: .invalidStream, code: .invalidStatusMetadata)),
        (["status": 1], .init(failure: .invalidStream, code: .invalidStatusMetadata)),
        (["session_id": UUID().uuidString], .init(failure: .invalidStream, code: .invalidStatusMetadata)),
        (["uuid": "invalid"], .init(failure: .invalidStream, code: .invalidStatusMetadata)),
        (["permissionMode": "acceptEdits"], .init(failure: .unsafeInitialization, code: .statusPermissionMismatch)),
        (["permissionMode": NSNull()], .init(failure: .unsafeInitialization, code: .statusPermissionMismatch))
    ]
    for (override, expected) in overrides {
        var stream = ClaudeTextOnlyStream(request: request)
        var event: [String: Any] = ["type": "system", "subtype": "status", "status": "requesting",
            "uuid": UUID().uuidString, "session_id": request.sessionID.uuidString]
        event.merge(override) { _, new in new }
        var emitted: [ClaudeTextOnlyEvent] = []
        #expect(throws: expected) { try stream.consume(textOnlyTestLine(event)) { emitted.append($0) } }
        #expect(emitted.isEmpty)
    }
}

@Test("Requesting status and compaction metadata grant no input acknowledgment or reply")
func claudeTextStreamRequestingStatusGrantsNoAuthority() throws {
    let request = try textOnlyTestRequest()
    let metadata = try textOnlyTestLine(["type": "system", "subtype": "status", "status": "requesting",
        "session_id": request.sessionID.uuidString, "uuid": UUID().uuidString,
        "permissionMode": "dontAsk", "compact_result": "failed", "compact_error": "synthetic private diagnostic"])
    var uninitialized = ClaudeTextOnlyStream(request: request)
    #expect(try uninitialized.consume(metadata).isEmpty)
    #expect(throws: ClaudeTextOnlyFailure.invalidStream) {
        try uninitialized.consume(textOnlyTestResult(request))
    }
    var unacknowledged = ClaudeTextOnlyStream(request: request)
    _ = try unacknowledged.consume(textOnlyTestInit(request))
    #expect(try unacknowledged.consume(metadata).isEmpty)
    _ = try unacknowledged.consume(textOnlyTestResult(request))
    #expect(unacknowledged.finish(exitCode: 0) == .failed(.invalidStream))
}

@Test("Contradictory replay flags and mixed content are not acceptance; the SDK marker is not required on raw wire")
func claudeTextStreamRequiresDocumentedReplayProof() throws {
    let request = try textOnlyTestRequest()
    var rawReplay = ClaudeTextOnlyStream(request: request)
    #expect(try rawReplay.consume(ClaudeTextOnlyCommandBuilder.input(for: request)) == [.inputAcknowledged(messageID: request.messageID)])
    let unconfirmed = try [textOnlyTestReplay(request, override: ["isReplay": false]),
        textOnlyTestReplay(request, override: ["isReplay": 1]),
        textOnlyTestReplay(request, override: ["isReplay": NSNull()])]
    for data in unconfirmed {
        var stream = ClaudeTextOnlyStream(request: request)
        #expect(throws: ClaudeTextOnlyRejection(failure: .invalidStream, code: .replayNotConfirmed)) {
            try stream.consume(data) { _ in Issue.record("Unproven echo emitted an acknowledgment") }
        }
    }
    let mixed: [[String: Any]] = [["type": "text", "text": request.text], ["type": "tool_result", "content": "ignored"]]
    var stream = ClaudeTextOnlyStream(request: request)
    #expect(throws: ClaudeTextOnlyRejection(failure: .invalidStream, code: .replayContentInvalid)) {
        try stream.consume(textOnlyTestReplay(request, override: ["message": ["role": "user", "content": mixed]])) { _ in
            Issue.record("Mixed content emitted an acknowledgment")
        }
    }
}

@Test("Initialization rejection carries a fixed diagnostic for the exact failing safety gate")
func claudeTextStreamStaticInitializationDiagnostics() throws {
    let request = try textOnlyTestRequest()
    let overrides: [([String: Any], ClaudeTextOnlyDiagnosticCode)] = [
        (["session_id": "wrong"], .initializationSessionMismatch),
        (["tools": ["Read"]], .initializationToolsInvalid),
        (["mcp_servers": [["name": "synthetic"]]], .initializationMCPInvalid),
        (["plugins": [["name": "synthetic"]]], .initializationPluginsInvalid),
        (["permissionMode": "acceptEdits"], .initializationPermissionMismatch),
        (["permissionMode": "bypassPermissions"], .initializationPermissionMismatch),
        (["permissionMode": "plan"], .initializationPermissionMismatch),
        (["apiKeySource": "synthetic-secret-never-returned"], .initializationKeySourceInvalid),
        (["model": "unrecognized-model-never-returned"], .initializationModelInvalid),
        // Loaded from a folder, which the command forbids: a skill, a slash
        // command, an agent this turn never defined, an output style.
        (["skills": ["planted-skill"]], .initializationExtensionsInvalid),
        (["slash_commands": ["planted-command"]], .initializationExtensionsInvalid),
        (["agents": [ClaudeTextHelperPolicy.agentType]], .initializationExtensionsInvalid),
        (["output_style": "planted-style"], .initializationExtensionsInvalid),
        (["skills": NSNull()], .initializationExtensionsInvalid)
    ]
    for (override, code) in overrides {
        var stream = ClaudeTextOnlyStream(request: request)
        #expect(throws: ClaudeTextOnlyRejection(failure: .unsafeInitialization, code: code)) {
            try stream.consume(textOnlyTestInit(request, override: override)) { _ in Issue.record("Unsafe init escaped") }
        }
    }
}

@Test("Missing terminal proof emits only a fixed incomplete-result diagnostic")
func claudeTextStreamStaticFinishDiagnostic() throws {
    let request = try textOnlyTestRequest()
    var stream = ClaudeTextOnlyStream(request: request)
    _ = try stream.consume(textOnlyTestInit(request))
    var codes: [ClaudeTextOnlyDiagnosticCode] = []
    #expect(stream.finish(exitCode: 0, onDiagnostic: { codes.append($0) }) == .failed(.invalidStream))
    #expect(codes == [.incompleteResult])
}

@Test("Raw CLI queue lifecycle and payload-free heartbeats do not interrupt a correlated reply")
func claudeTextStreamRawTransportMetadata() throws {
    let request = try textOnlyTestRequest()
    var stream = ClaudeTextOnlyStream(request: request)
    let heartbeat = try textOnlyTestLine(["type": "keep_alive"])
    var frames = try textOnlyTestCommandLifecycle(request, state: "queued") + heartbeat
    frames += try textOnlyTestInit(request) + textOnlyTestCommandLifecycle(request, state: "started")
    frames += try textOnlyTestReplay(request) + textOnlyTestDelta(request, text: "Hello ")
    frames += try textOnlyTestResult(request) + textOnlyTestCommandLifecycle(request, state: "completed") + heartbeat
    #expect(try stream.consume(frames) == [
        .initialized(sessionID: request.sessionID, actualModel: "claude-sonnet-5"),
        .inputAcknowledged(messageID: request.messageID), .textSnapshot("Hello "), .textSnapshot("Hello back")
    ])
    #expect(stream.finish(exitCode: 0) == .success(.init(sessionID: request.sessionID,
        actualModel: "claude-sonnet-5", text: "Hello back", confirmedActualModel: "claude-sonnet-5")))
}

@Test("Transport metadata alone grants no initialization, acknowledgment or successful result")
func claudeTextStreamTransportMetadataGrantsNoAuthority() throws {
    let request = try textOnlyTestRequest()
    var stream = ClaudeTextOnlyStream(request: request)
    for state in ["queued", "started", "completed"] {
        #expect(try stream.consume(textOnlyTestCommandLifecycle(request, state: state)).isEmpty)
    }
    #expect(try stream.consume(textOnlyTestLine(["type": "keep_alive"])).isEmpty)
    #expect(stream.finish(exitCode: 0) == .failed(.invalidStream))
    _ = try stream.consume(textOnlyTestInit(request) + textOnlyTestResult(request))
    #expect(stream.finish(exitCode: 0) == .failed(.invalidStream))
}

@Test("Queue lifecycle requires the frozen command and session with valid event identity and known state")
func claudeTextStreamRejectsUncorrelatedLifecycle() throws {
    let request = try textOnlyTestRequest()
    let overrides: [[String: Any]] = [
        ["command_uuid": UUID().uuidString], ["command_uuid": NSNull()],
        ["session_id": UUID().uuidString], ["session_id": "invalid"],
        ["uuid": "invalid"], ["uuid": NSNull()], ["state": "unknown"], ["state": 1]
    ]
    for override in overrides {
        var stream = ClaudeTextOnlyStream(request: request)
        #expect(throws: ClaudeTextOnlyRejection(failure: .invalidStream, code: .invalidCommandLifecycle)) {
            try stream.consume(textOnlyTestCommandLifecycle(request, state: "queued", override: override)) { _ in
                Issue.record("Uncorrelated lifecycle emitted a reply event")
            }
        }
    }
    for state in ["cancelled", "discarded", "refused"] {
        var stream = ClaudeTextOnlyStream(request: request)
        #expect(throws: ClaudeTextOnlyRejection(failure: .invalidStream, code: .commandLifecycleRejected)) {
            try stream.consume(textOnlyTestCommandLifecycle(request, state: state)) { _ in
                Issue.record("Rejected command emitted a reply event")
            }
        }
    }
}

@Test("Only the exact payload-free heartbeat is ignored")
func claudeTextStreamRejectsHeartbeatPayload() throws {
    let extras: [[String: Any]] = [["session_id": UUID().uuidString], ["payload": "private synthetic value"],
                                 ["parent_tool_use_id": NSNull()], ["request": ["subtype": "can_use_tool"]]]
    for extra in extras {
        var stream = ClaudeTextOnlyStream(request: try textOnlyTestRequest())
        var event: [String: Any] = ["type": "keep_alive"]
        event.merge(extra) { _, new in new }
        #expect(throws: ClaudeTextOnlyRejection(failure: .invalidStream, code: .invalidKeepAlive)) {
            try stream.consume(textOnlyTestLine(event)) { _ in Issue.record("Heartbeat payload escaped") }
        }
    }
}

@Test("Unknown unsafe and known substantive data after a result still fail")
func claudeTextStreamRejectsOtherEventsAfterResult() throws {
    let request = try textOnlyTestRequest()
    let suffixes = try [
        textOnlyTestLine(["type": "unrecognized-synthetic-event"]),
        textOnlyTestLine(["type": "telemetry_event", "session_id": request.sessionID.uuidString,
            "category": "control_request", "source": "auth", "phase": "tool_use"]),
        textOnlyTestLine(["type": "assistant", "session_id": request.sessionID.uuidString,
            "message": ["role": "assistant", "model": "claude-sonnet-5", "content": []]]),
        textOnlyTestResult(request)
    ]
    for suffix in suffixes {
        var stream = ClaudeTextOnlyStream(request: request)
        var emitted: [ClaudeTextOnlyEvent] = []
        let frames = try textOnlyTestInit(request) + textOnlyTestReplay(request)
            + textOnlyTestResult(request) + suffix
        #expect(throws: ClaudeTextOnlyRejection(failure: .invalidStream, code: .eventAfterResult)) {
            try stream.consume(frames) { emitted.append($0) }
        }
        #expect(emitted.filter { $0 == .textSnapshot("Hello back") }.count == 1)
    }
}

@Test("The CLI's retry notice lets it retry: the turn does not fail on it, and the budget is finite")
func claudeTextStreamLetsTheCLIRetry() throws {
    let request = try textOnlyTestRequest()
    // The frame as the 2.1.263 binary writes it: retry counters, the failed
    // request's status, its error snapshot and, sometimes, a no-response detail.
    func retry(_ extra: [String: Any] = [:]) throws -> Data {
        var value: [String: Any] = ["type": "system", "subtype": "api_retry", "session_id": request.sessionID.uuidString,
            "uuid": UUID().uuidString, "attempt": 1, "max_retries": 10, "retry_delay_ms": 2_000, "error_status": 529,
            "error": ["name": "APIError", "message": "overloaded", "status": 529],
            "no_response": ["waited_ms": 60_000, "retry_wait_ms": 1_000]]
        value.merge(extra) { _, new in new }
        return try textOnlyTestLine(value)
    }
    var stream = ClaudeTextOnlyStream(request: request)
    var frames = try textOnlyTestInit(request)
    frames += try retry()
    frames += try textOnlyTestReplay(request)
    frames += try retry(["error_status": NSNull()])
    frames += try textOnlyTestDelta(request, text: "Hello ")
    frames += try textOnlyTestResult(request)
    #expect(try stream.consume(frames) == [
        .initialized(sessionID: request.sessionID, actualModel: "claude-sonnet-5"),
        .inputAcknowledged(messageID: request.messageID), .textSnapshot("Hello "), .textSnapshot("Hello back")
    ])
    #expect(stream.apiRetryFrameCount == 2)
    #expect(stream.finish(exitCode: 0) == .success(.init(sessionID: request.sessionID,
        actualModel: "claude-sonnet-5", text: "Hello back", confirmedActualModel: "claude-sonnet-5")))
    // Before initialization it is still a provider failure, and so is a frame
    // for another session, one with a key that was never reviewed, or one
    // whose counters are not numbers.
    var early = ClaudeTextOnlyStream(request: request)
    #expect(throws: ClaudeTextOnlyFailure.providerFailed) { try early.consume(retry()) }
    let refused: [[String: Any]] = [["session_id": UUID().uuidString], ["message": "retrying"],
                                    ["attempt": "one"], ["retry_delay_ms": NSNull()]]
    for extra in refused {
        var rejecting = ClaudeTextOnlyStream(request: request)
        _ = try rejecting.consume(textOnlyTestInit(request))
        #expect(throws: ClaudeTextOnlyFailure.providerFailed) { try rejecting.consume(retry(extra)) }
    }
    var flooded = ClaudeTextOnlyStream(request: request)
    _ = try flooded.consume(textOnlyTestInit(request))
    for _ in 0..<ClaudeTextOnlyStream.maximumAPIRetryFrames { _ = try flooded.consume(retry()) }
    #expect(throws: ClaudeTextOnlyFailure.providerFailed) { try flooded.consume(retry()) }
}

// Convenience for the original all-success or immediate-failure unit cases.
// Production exposes only callback delivery so a throwing batch cannot discard
// its validated prefix. Prefix/error regressions above exercise that API directly.
private extension ClaudeTextOnlyStream {
    mutating func consume(_ data: Data) throws -> [ClaudeTextOnlyEvent] {
        var events: [ClaudeTextOnlyEvent] = []
        do { try consume(data) { events.append($0) } }
        catch let rejection as ClaudeTextOnlyRejection { throw rejection.failure }
        return events
    }
}

@Test("A refused control request's shape names the nested subtype, tool and agent presence, never a value")
func refusedControlRequestShapeNamesTheQuestion() throws {
    let request = try textOnlyTestRequest()
    let root: [String: Any] = [
        "type": "control_request", "request_id": "6f0d",
        "request": ["subtype": "can_use_tool", "tool_name": "Bash", "tool_use_id": "toolu_1",
                    "agent_id": "agent-1", "input": ["command": "curl https://example.com"]],
    ]
    let stream = ClaudeTextOnlyStream(request: request)
    let shape = stream.refusalShape(root)
    #expect(shape.hasPrefix("type=control_request subtype=- keys=[request:object request_id:string(4) type:string(15)]"))
    #expect(shape.contains("request=[subtype:can_use_tool tool_name:Bash agent_id:set keys:agent_id,input,subtype,tool_name,tool_use_id]"))
    #expect(shape.contains("questions=0 duplicate=false initialized=false completed=false"))
    #expect(!shape.contains("curl"))
    var odd = root
    odd["request"] = ["subtype": "can_use_tool", "tool_name": "We ird\u{0}", "agent_id": NSNull()]
    #expect(stream.refusalShape(odd).contains("request=[subtype:can_use_tool tool_name:? agent_id:none keys:agent_id,subtype,tool_name]"))
    let plain: [String: Any] = ["type": "result", "subtype": "success"]
    #expect(stream.refusalShape(plain) == "type=result subtype=success keys=[subtype:string(7) type:string(6)]")
}

@Test("A refused stream event's shape names the event, block, delta, stop reason and model, never text")
func refusedStreamEventShapeNamesTheEvent() throws {
    let request = try textOnlyTestRequest()
    let stream = ClaudeTextOnlyStream(request: request)
    let delta: [String: Any] = [
        "type": "stream_event", "session_id": request.sessionID.uuidString, "uuid": "u", "parent_tool_use_id": NSNull(),
        "event": ["type": "content_block_delta", "index": 0, "delta": ["type": "citations_delta", "citation": ["cited_text": "secret"]]],
    ]
    #expect(stream.refusalShape(delta).contains("event=[type:content_block_delta block:- delta:citations_delta stop_reason:- model:-]"))
    #expect(!stream.refusalShape(delta).contains("secret"))
    let stop: [String: Any] = ["type": "stream_event", "event": ["type": "message_delta", "delta": ["stop_reason": "refusal", "stop_sequence": NSNull()]]]
    #expect(stream.refusalShape(stop).contains("event=[type:message_delta block:- delta:- stop_reason:refusal model:-]"))
    let start: [String: Any] = ["type": "stream_event", "event": ["type": "message_start", "message": ["model": "claude-sonnet-5", "role": "assistant", "content": []]]]
    #expect(stream.refusalShape(start).contains("event=[type:message_start block:- delta:- stop_reason:- model:claude-sonnet-5]"))
    let block: [String: Any] = ["type": "stream_event", "event": ["type": "content_block_start", "content_block": ["type": "server_tool_use", "name": "web search"]]]
    #expect(stream.refusalShape(block).contains("event=[type:content_block_start block:server_tool_use delta:- stop_reason:- model:-]"))
}

/// A model that declines is the bot deciding, not a broken stream. A `refusal`
/// stop reason once threw `responseMismatch`, so the person read "Claude's response could not be verified" about a turn in which
/// nothing had gone wrong.
@Test("A refusal stop reason ends the turn as declined, keeping the text already delivered")
func refusalStopReasonEndsTheTurnWithoutRejecting() throws {
    let request = try textOnlyTestRequest()
    let refusal = try textOnlyTestLine(["type": "stream_event", "session_id": request.sessionID.uuidString,
        "event": ["type": "message_delta", "delta": ["stop_reason": "refusal", "stop_sequence": NSNull()]]])
    var stream = ClaudeTextOnlyStream(request: request)
    var events: [ClaudeTextOnlyEvent] = []
    try stream.consume(textOnlyTestInit(request) + textOnlyTestReplay(request)
        + textOnlyTestDelta(request, text: "Here is what I had started") + refusal) { events.append($0) }
    #expect(events.contains(.textSnapshot("Here is what I had started")))
    #expect(stream.textSoFar == "Here is what I had started")
    #expect(stream.finish(exitCode: 0) == .failed(.declined))

    // The run that follows a refusal ends with no answer to carry. An empty
    // or failed result is a provider failure everywhere else; after a refusal
    // it is the decline, and it closes the turn so the transport stops waiting.
    for terminal in [["result": "", "is_error": true, "subtype": "error_during_execution"],
                     ["result": "", "is_error": false]] {
        var withResult = ClaudeTextOnlyStream(request: request)
        try withResult.consume(textOnlyTestInit(request) + textOnlyTestReplay(request) + refusal) { _ in }
        try withResult.consume(textOnlyTestResult(request, override: terminal)) { _ in }
        #expect(withResult.hasCompleted)
        #expect(withResult.finish(exitCode: 0) == .failed(.declined))
    }

    // A refusal underneath a granted call is that call's own business. The
    // parent turn is still free to answer, and its answer stands.
    let granted = try textOnlyTestRequest(allowedTools: [.webSearch])
    var nested = ClaudeTextOnlyStream(request: granted)
    try nested.consume(textOnlyTestInit(granted, override: ["tools": ["WebSearch"]])) { _ in }
    try nested.consume(textOnlyTestReplay(granted)) { _ in }
    try nested.consume(textOnlyTestLine(["type": "assistant", "session_id": granted.sessionID.uuidString,
        "message": ["role": "assistant", "model": granted.expectedResolvedModel,
                    "content": [["type": "tool_use", "id": "search-1", "name": "WebSearch",
                                 "input": ["query": "test"]]]]])) { _ in }
    try nested.consume(textOnlyTestLine(["type": "stream_event", "session_id": granted.sessionID.uuidString,
        "parent_tool_use_id": "search-1",
        "event": ["type": "message_delta", "delta": ["stop_reason": "refusal", "stop_sequence": NSNull()]]])) { _ in }
    try nested.consume(textOnlyTestResult(granted, override: ["result": "Parent answer"])) { _ in }
    #expect(nested.finish(exitCode: 0) == .success(.init(sessionID: granted.sessionID,
        actualModel: granted.expectedResolvedModel, text: "Parent answer",
        confirmedActualModel: granted.expectedResolvedModel)))
}

/// Claude Code 2.1.280 to
/// 2.1.282 write a `system` frame when the model refuses and no other model
/// takes over, and another when one does. Both were refused as
/// `unexpectedSystemEvent`, so a decline read as "sent something OpenBots does
/// not understand". The frames are built from the 2.1.282 bundle's own
/// stream-json serializer (the `Fe({type:"system",subtype:"model_refusal_…"})`
/// branches), not captured: a provider refusal is not something to provoke.
func refusalNoFallbackFrame(_ request: ClaudeTextOnlyRequest, override: [String: Any] = [:]) throws -> Data {
    var frame: [String: Any] = ["type": "system", "subtype": "model_refusal_no_fallback",
        "uuid": "2f0c3b64-7a51-4d7e-9a53-0d6b1a7c9e11", "session_id": request.sessionID.uuidString.lowercased(),
        "original_model": request.expectedResolvedModel, "request_id": "req_011CfPtvso4KShikxL4bzAwN",
        "api_refusal_category": NSNull(), "api_refusal_explanation": NSNull(), "refused_user_message_uuid": NSNull(),
        "content": ""]
    for (key, value) in override { frame[key] = value }
    return try textOnlyTestLine(frame)
}

@Test("The CLI's refusal frame with no fallback ends the turn as declined, with or without a refusal stop reason before it")
func refusalNoFallbackFrameDeclines() throws {
    let request = try textOnlyTestRequest()
    let stopReason = try textOnlyTestLine(["type": "stream_event", "session_id": request.sessionID.uuidString,
        "event": ["type": "message_delta", "delta": ["stop_reason": "refusal", "stop_sequence": NSNull()]]])
    for (leadIn, terminal) in [(stopReason, ["result": "", "is_error": true, "subtype": "error_during_execution"] as [String: Any]),
                               (stopReason, ["result": "", "is_error": false] as [String: Any]),
                               (Data(), ["result": "", "is_error": false] as [String: Any])] {
        var stream = ClaudeTextOnlyStream(request: request)
        try stream.consume(textOnlyTestInit(request) + textOnlyTestReplay(request)
            + textOnlyTestDelta(request, text: "I started") + leadIn + refusalNoFallbackFrame(request,
                override: ["api_refusal_category": "cyber", "api_refusal_explanation": "Declined by policy.",
                           "refused_user_message_uuid": request.messageID.uuidString.lowercased()])) { _ in }
        try stream.consume(textOnlyTestResult(request, override: terminal)) { _ in }
        #expect(stream.hasCompleted)
        var diagnostics: [ClaudeTextOnlyDiagnosticCode] = []
        #expect(stream.finish(exitCode: 0) { diagnostics.append($0) } == .failed(.declined))
        #expect(diagnostics.isEmpty)
    }
}

@Test("A refusal frame for another session, under a tool call, with a key the CLI never writes or a value too long is refused")
func refusalNoFallbackFrameIsChecked() throws {
    let request = try textOnlyTestRequest()
    for override: [String: Any] in [["session_id": UUID().uuidString.lowercased()],
                                    ["parent_tool_use_id": "toolu_1"],
                                    ["model": "claude-opus-5"],
                                    ["content": String(repeating: "x", count: 5_000)],
                                    ["original_model": 7]] {
        var stream = ClaudeTextOnlyStream(request: request)
        try stream.consume(textOnlyTestInit(request) + textOnlyTestReplay(request)) { _ in }
        #expect(throws: ClaudeTextOnlyRejection.self, "\(override.keys)") {
            try stream.consume(refusalNoFallbackFrame(request, override: override)) { _ in }
        }
    }
}

@Test("A refusal frame that hands the reply to another model ends the turn as declined at that frame")
func refusalFallbackFrameEndsTheTurnAsDeclined() throws {
    let request = try textOnlyTestRequest()
    var stream = ClaudeTextOnlyStream(request: request)
    try stream.consume(textOnlyTestInit(request) + textOnlyTestReplay(request) + textOnlyTestDelta(request, text: "I started")) { _ in }
    let fallback = try textOnlyTestLine(["type": "system", "subtype": "model_refusal_fallback",
        "uuid": "6b1f2e0a-3c4d-4e5f-8a9b-0c1d2e3f4a5b", "session_id": request.sessionID.uuidString.lowercased(),
        "trigger": "refusal", "direction": "retry", "scope": "local", "original_model": request.expectedResolvedModel,
        "fallback_model": "claude-opus-5", "request_id": "req_1", "api_refusal_category": NSNull(),
        "api_refusal_explanation": NSNull(), "refused_user_message_uuid": NSNull(), "content": "Switched model."])
    #expect(throws: ClaudeTextOnlyRejection(failure: .declined, code: .unexpectedSystemEvent)) {
        try stream.consume(fallback) { _ in }
    }
    #expect(stream.textSoFar == "I started")
}

@Test("Claude Code 2.1.272 forces the default permission mode under the app's environment scrub; a turn with no control channel accepts it, because its fences are the empty tool set and the deny list, not the mode")
func forcedDefaultModeIsAcceptedWithoutAControlChannel() throws {
    // The init frame exactly as the installed CLI (2.1.272)
    // announced it for the shipped tool-free command, session id substituted.
    // Its stderr said: "Permission mode forced to default —
    // CLAUDE_CODE_SUBPROCESS_ENV_SCRUB is set (allowed_non_write_users hardening)".
    func realInit(_ request: ClaudeTextOnlyRequest, tools: [String]) -> [String: Any] {
        ["agents": [], "analytics_disabled": true, "apiKeySource": "none",
         "capabilities": ["interrupt_receipt_v1", "interrupt_cancel_queued_v1", "msg_lifecycle_v1"],
         "claude_code_version": "2.1.272", "cwd": "/private/tmp/bot-desk.noindex/Yogurt",
         "fast_mode_disabled_reason": "sdk_opt_in_required", "fast_mode_state": "off", "mcp_servers": [],
         "messaging_socket_path": "/tmp/cc-socks-501/78135.sock", "model": request.expectedResolvedModel,
         "output_style": "default", "permissionMode": "default", "plugins": [], "product_feedback_disabled": true,
         "session_id": request.sessionID.uuidString.lowercased(), "skills": [], "slash_commands": [],
         "subtype": "init", "tools": tools, "type": "system", "uuid": UUID().uuidString.lowercased()]
    }
    let text = try textOnlyTestRequest(model: "claude-haiku-4-5-20251001")
    var stream = ClaudeTextOnlyStream(request: text)
    #expect(try stream.consume(textOnlyTestLine(realInit(text, tools: []))) == [.initialized(sessionID: text.sessionID, actualModel: "claude-haiku-4-5-20251001"), .runtimeVersion("2.1.272")])
    // The status frames of the same CLI carry the same forced mode.
    #expect(try stream.consume(textOnlyTestLine(["type": "system", "subtype": "status", "status": "requesting",
        "uuid": UUID().uuidString, "session_id": text.sessionID.uuidString, "permissionMode": "default"])).isEmpty)
    let web = try textOnlyTestRequest(allowedTools: [.webSearch, .webFetch])
    var webStream = ClaudeTextOnlyStream(request: web)
    #expect(try webStream.consume(textOnlyTestLine(realInit(web, tools: ["WebFetch", "WebSearch"]))) == [.initialized(sessionID: web.sessionID, actualModel: web.expectedResolvedModel), .runtimeVersion("2.1.272")])
    // The command line still asks for dontAsk, byte for byte as reviewed.
    #expect(ClaudeTextOnlyCommandBuilder.arguments(for: text).contains("dontAsk"))
    // A mode that would let the CLI act without asking, or that plans instead of answering, still closes the turn.
    for mode in ["acceptEdits", "bypassPermissions", "plan", "dontask", ""] {
        var wrong = ClaudeTextOnlyStream(request: text)
        #expect(throws: ClaudeTextOnlyRejection(failure: .unsafeInitialization, code: .initializationPermissionMismatch)) {
            try wrong.consume(textOnlyTestInit(text, override: ["permissionMode": mode])) { _ in Issue.record("\(mode) escaped") }
        }
        var status = ClaudeTextOnlyStream(request: text)
        #expect(throws: ClaudeTextOnlyRejection(failure: .unsafeInitialization, code: .statusPermissionMismatch)) {
            try status.consume(textOnlyTestLine(["type": "system", "subtype": "status", "status": "requesting",
                "uuid": UUID().uuidString, "session_id": text.sessionID.uuidString, "permissionMode": mode])) { _ in }
        }
    }
}

@Test("The init frame names the Claude Code version, and the parser passes it on when it is a plain version")
func initFrameNamesTheClaudeCodeVersion() throws {
    let request = try textOnlyTestRequest()
    var stream = ClaudeTextOnlyStream(request: request)
    #expect(try stream.consume(textOnlyTestInit(request, override: ["claude_code_version": "2.1.272", "permissionMode": "default"]))
        == [.initialized(sessionID: request.sessionID, actualModel: request.expectedResolvedModel), .runtimeVersion("2.1.272")])
    // A CLI that says nothing about its version, or says something that is not a version, adds nothing and breaks nothing.
    var silent = ClaudeTextOnlyStream(request: request)
    #expect(try silent.consume(textOnlyTestInit(request)) == [.initialized(sessionID: request.sessionID, actualModel: request.expectedResolvedModel)])
    for odd in ["2.1.272 <script>", "", String(repeating: "9", count: 40), "v2"] {
        var stream = ClaudeTextOnlyStream(request: request)
        #expect(try stream.consume(textOnlyTestInit(request, override: ["claude_code_version": odd]))
            == [.initialized(sessionID: request.sessionID, actualModel: request.expectedResolvedModel)], Comment(rawValue: odd))
    }
}

@Test("A resumed turn whose session the CLI no longer holds is named as a lost session, not an unverifiable reply")
func lostSessionIsNamed() throws {
    // The frame exactly as 2.1.272 sent it for `--resume 00000000-dead-beef-…`:
    // no init, one error result, nothing else.
    let request = try textOnlyTestRequest(resumesSession: true)
    let frame: [String: Any] = [
        "type": "result", "subtype": "error_during_execution", "duration_ms": 0, "duration_api_ms": 0,
        "is_error": true, "num_turns": 0, "stop_reason": NSNull(), "session_id": request.sessionID.uuidString.lowercased(),
        "total_cost_usd": 0, "usage": ["input_tokens": 0, "output_tokens": 0], "modelUsage": [String: Any](),
        "permission_denials": [], "result_index": 0, "uuid": UUID().uuidString.lowercased(),
        "errors": ["No conversation found with session ID: \(request.sessionID.uuidString.lowercased())"],
    ]
    var stream = ClaudeTextOnlyStream(request: request)
    var codes: [ClaudeTextOnlyDiagnosticCode] = []
    #expect(throws: ClaudeTextOnlyRejection(failure: .sessionNotFound, code: .sessionNotFound)) {
        try stream.consume(textOnlyTestLine(frame)) { if case .diagnostic(let code) = $0 { codes.append(code) } }
    }
    // The same frame on a turn that never asked to resume is still a broken stream.
    let freshRequest = try textOnlyTestRequest()
    var fresh = ClaudeTextOnlyStream(request: freshRequest)
    let freshFrame = frame.merging(["session_id": freshRequest.sessionID.uuidString.lowercased()]) { _, new in new }
    #expect(throws: ClaudeTextOnlyRejection(failure: .invalidStream, code: .responseMismatch)) {
        try fresh.consume(textOnlyTestLine(freshFrame)) { _ in }
    }
    // An error result naming anything else is not a lost session.
    var other = ClaudeTextOnlyStream(request: request)
    let otherFrame = frame.merging(["errors": ["Something else went wrong"]]) { _, new in new }
    #expect(throws: ClaudeTextOnlyRejection(failure: .invalidStream, code: .responseMismatch)) {
        try other.consume(textOnlyTestLine(otherFrame)) { _ in }
    }
    // Nor is one with no session id, or with another session's.
    for session in [nil, UUID().uuidString.lowercased()] as [String?] {
        var unnamed = ClaudeTextOnlyStream(request: request)
        var unnamedFrame = frame
        unnamedFrame["session_id"] = session
        #expect(throws: ClaudeTextOnlyRejection(failure: .invalidStream, code: .responseMismatch)) {
            try unnamed.consume(textOnlyTestLine(unnamedFrame)) { _ in }
        }
    }
}
