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
    let overrides: [[String: Any]] = [["is_error": true], ["is_error": 0], ["subtype": "error_max_turns"],
                                     ["result": " "], ["permission_denials": [["tool_name": "Read"]]]]
    for override in overrides {
        var stream = ClaudeTextOnlyStream(request: request)
        _ = try stream.consume(textOnlyTestInit(request))
        #expect(throws: ClaudeTextOnlyFailure.providerFailed) { try stream.consume(textOnlyTestResult(request, override: override)) }
    }
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
        (["permissionMode": "default"], .initializationPermissionMismatch),
        (["apiKeySource": "synthetic-secret-never-returned"], .initializationKeySourceInvalid),
        (["model": "unrecognized-model-never-returned"], .initializationModelInvalid)
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
    let frames = try textOnlyTestCommandLifecycle(request, state: "queued") + heartbeat
        + textOnlyTestInit(request) + textOnlyTestCommandLifecycle(request, state: "started")
        + textOnlyTestReplay(request) + textOnlyTestDelta(request, text: "Hello ")
        + textOnlyTestResult(request) + textOnlyTestCommandLifecycle(request, state: "completed") + heartbeat
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
