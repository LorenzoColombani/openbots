import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsRuntime

private let macServerName = "openbots_" + String(repeating: "5ac0", count: 16)
private let browserServerName = "openbots_" + String(repeating: "b0e5", count: 16)

private func macControlRequest() throws -> ClaudeTextOnlyRequest {
    let server = try ClaudeTextConnectorServer(name: macServerName, role: .macControl,
        program: .installedTool(URL(fileURLWithPath: "/private/tmp/openbots-peekaboo-fixture")), options: [], environment: [:])
    return try textOnlyTestRequest(connectorAccess: try ClaudeTextConnectorAccess(servers: [server]))
}

private func browserRequest() throws -> ClaudeTextOnlyRequest {
    try textOnlyTestRequest(connectorAccess: try ClaudeTextConnectorAccess(servers: [connectorServerFixture(name: browserServerName)]))
}

/// One connector call in the order the 2.1.272 work capture shows a granted
/// call travelling: the block starts, the assistant message carries it, the CLI
/// asks, the host's answer is echoed back, and the result arrives.
private func connectorCallFrames(_ request: ClaudeTextOnlyRequest, server: String, index: Int) throws -> [Data] {
    let id = "toolu_budget_\(index)", tool = "mcp__\(server)__click"
    let session = request.sessionID.uuidString
    return [
        try textOnlyTestLine(["type": "stream_event", "session_id": session,
            "event": ["type": "content_block_start", "index": 1,
                      "content_block": ["type": "tool_use", "id": id, "name": tool, "input": [:]]]]),
        try textOnlyTestLine(["type": "assistant", "session_id": session,
            "message": ["role": "assistant", "model": request.expectedResolvedModel,
                        "content": [["type": "tool_use", "id": id, "name": tool, "input": ["query": "Next"]]]]]),
        try textOnlyTestLine(["type": "control_request", "request_id": "req-\(index)", "session_id": session,
            "request": ["subtype": "can_use_tool", "tool_name": tool, "tool_use_id": id, "input": ["query": "Next"]]]),
        try textOnlyTestLine(["type": "control_response",
            "response": ["subtype": "success", "request_id": "req-\(index)", "response": ["behavior": "allow"]]]),
        try textOnlyTestLine(["type": "user", "uuid": UUID().uuidString, "session_id": session, "parent_tool_use_id": NSNull(),
            "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": "done"]]]]),
    ]
}

private struct ReplyStop {
    var call: Int
    /// Which of the call's frames was refused: 0 its block start, 2 the question, 3 the echo.
    var frame: Int
    var rejection: ClaudeTextOnlyRejection
}

/// Feeds whole calls, each asked and allowed, until the stream refuses a frame.
private func feedCalls(_ request: ClaudeTextOnlyRequest, server: String, upTo calls: Int) throws
    -> (stream: ClaudeTextOnlyStream, stop: ReplyStop?) {
    var stream = ClaudeTextOnlyStream(request: request, control: ClaudeTextTurnControl())
    stream.expectControlInitialization(requestID: "init-1")
    try stream.consume(try textOnlyTestLine(["type": "control_response",
        "response": ["subtype": "success", "request_id": "init-1", "response": [String: Any]()]])) { _ in }
    try stream.consume(try textOnlyTestInit(request, override: [
        "tools": request.grantedToolNames + request.appServerToolNames + ["mcp__\(server)__click"],
        "mcp_servers": [["name": server, "status": "connected"]] + appServerEntries(request), "permissionMode": "default"])) { _ in }
    try stream.consume(try textOnlyTestReplay(request)) { _ in }
    for call in 1...calls {
        for (frame, data) in try connectorCallFrames(request, server: server, index: call).enumerated() {
            do { try stream.consume(data) { _ in } } catch let rejection as ClaudeTextOnlyRejection {
                return (stream, ReplyStop(call: call, frame: frame, rejection: rejection))
            }
        }
    }
    return (stream, nil)
}

@Test("A Control this Mac reply has its own larger budget of calls, questions and echoes, and the call past it ends the reply as the app's own limit")
func macControlReplyHasItsOwnBudget() throws {
    let budget = ClaudeTextOnlyStream.maximumGrantedToolUses + ClaudeTextOnlyStream.maximumMacControlCalls
    let (stream, stop) = try feedCalls(try macControlRequest(), server: macServerName, upTo: budget + 1)
    let stopped = try #require(stop)
    // Every call inside the budget was asked, answered, echoed and finished.
    #expect(stream.grantedToolUseCount == budget)
    #expect(stream.permissionRequestCount == budget)
    #expect(stream.grantedToolResultCount == budget)
    // The one past it is refused as it starts, before its question: the app's
    // own limit, which keeps what streamed, never a broken stream.
    #expect(stopped.call == budget + 1)
    #expect(stopped.frame == 0)
    #expect(stopped.rejection == ClaudeTextOnlyRejection(failure: .turnLimitReached, code: .turnLimitReached))
}

@Test("A browser turn keeps the ordinary budget: its sixty-fifth call ends the reply as it starts")
func otherConnectorTurnsKeepTheOrdinaryBudget() throws {
    let budget = ClaudeTextOnlyStream.maximumGrantedToolUses
    let (stream, stop) = try feedCalls(try browserRequest(), server: browserServerName, upTo: budget + 1)
    let stopped = try #require(stop)
    #expect(stream.grantedToolUseCount == budget)
    #expect(stream.permissionRequestCount == budget)
    #expect(stopped.call == budget + 1)
    #expect(stopped.frame == 0)
    #expect(stopped.rejection == ClaudeTextOnlyRejection(failure: .turnLimitReached, code: .turnLimitReached))
}
