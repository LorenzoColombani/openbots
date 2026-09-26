import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsRuntime

// Throwaway workers. A bot holding the workers switch
// is offered `spawn_worker` on the app's own `openbots` server, beside the hire
// tool and the login handoff, over the same control channel. These pin the
// command such a turn launches with and the host's answers on the wire.

private func value(_ arguments: [String], _ flag: String) -> String? {
    arguments.firstIndex(of: flag).map { arguments[$0 + 1] }
}

private func json(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func mcpFrame(id: String, message: [String: Any]) throws -> Data {
    try textOnlyTestLine(["type": "control_request", "request_id": id,
                          "request": ["subtype": "mcp_message", "server_name": ClaudeTextHirePolicy.serverName,
                                      "message": message]])
}

private func listedTools(_ frame: Data) throws -> [String] {
    let reply = try #require(((try json(frame)["response"] as? [String: Any])?["response"] as? [String: Any])?["mcp_response"] as? [String: Any])
    let tools = try #require((reply["result"] as? [String: Any])?["tools"] as? [[String: Any]])
    return tools.compactMap { $0["name"] as? String }
}

@Test("A web bot holding workers launches in the connector-turn shape: the channel, the question tool, the worker name allowed, no server wildcard denied")
func webWithWorkersCommandContract() throws {
    let request = try textOnlyTestRequest(allowedTools: [.webSearch], grantsWorkers: true)
    #expect(request.grantsWorkers && request.carriesAppServer && request.requiresPermissionControl)
    #expect(request.appServerToolNames == [ClaudeTextWorkerPolicy.qualifiedToolName])
    let arguments = ClaudeTextOnlyCommandBuilder.arguments(for: request)
    #expect(value(arguments, "--tools") == "AskUserQuestion,WebSearch")
    #expect(value(arguments, "--permission-mode") == "default")
    #expect(value(arguments, "--permission-prompt-tool") == "stdio")
    let denied = try #require(value(arguments, "--disallowedTools")).split(separator: ",").map(String.init)
    #expect(!denied.contains("mcp__*"), "the wildcard would shadow the worker tool")
    let settings = try json(Data(ClaudeTextOnlyCommandBuilder.settingsJSON(for: request).utf8))
    let permissions = try #require(settings["permissions"] as? [String: Any])
    #expect(permissions["defaultMode"] as? String == "default")
    #expect(permissions["allow"] as? [String] == ["WebSearch", "mcp__openbots__spawn_worker"])
    #expect(permissions["deny"] as? [String] == denied)
    #expect(ClaudeTextWorkerPolicy.qualifiedToolName == "mcp__\(ClaudeTextWorkerPolicy.serverName)__\(ClaudeTextWorkerPolicy.toolName)")
    // The handshake opens the app's server.
    let handshake = try json(try ClaudeTextOnlyCommandBuilder.initializeControlRecord(id: "c1", appServer: request.carriesAppServer))
    let body = try #require(handshake["request"] as? [String: Any])
    #expect(body["sdkMcpServers"] as? [String] == [ClaudeTextHirePolicy.serverName])
}

@Test("Work with workers and hiring allows both server names, and the helper can neither hire nor spawn")
func workWithWorkersKeepsTheHelperFenced() throws {
    let work = try ClaudeTextWorkAccess(workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/desk.noindex"),
                                        protectedPaths: ["/Users/x/.ssh"])
    let request = try textOnlyTestRequest(workAccess: work, grantsHiring: true, grantsWorkers: true)
    let without = try textOnlyTestRequest(workAccess: work)
    #expect(request.appServerToolNames == [ClaudeTextHirePolicy.qualifiedToolName, ClaudeTextWorkerPolicy.qualifiedToolName])
    let arguments = ClaudeTextOnlyCommandBuilder.arguments(for: request)
    #expect(value(arguments, "--tools") == value(ClaudeTextOnlyCommandBuilder.arguments(for: without), "--tools"))
    let settings = try json(Data(ClaudeTextOnlyCommandBuilder.settingsJSON(for: request).utf8))
    let permissions = try #require(settings["permissions"] as? [String: Any])
    #expect(permissions["allow"] as? [String] == ["mcp__openbots__hire_teammate", "mcp__openbots__spawn_worker"])
    let helpers = try json(Data(try #require(value(arguments, "--agents")).utf8))
    let helper = try #require(helpers[ClaudeTextHelperPolicy.agentType] as? [String: Any])
    #expect(!(helper["tools"] as? [String] ?? []).contains { $0.hasPrefix("mcp__") })
    #expect((helper["disallowedTools"] as? [String] ?? []).contains("mcp__*"))
    #expect(value(arguments, "--agents") == value(ClaudeTextOnlyCommandBuilder.arguments(for: without), "--agents"))
}

@Test("The server lists exactly the tools the turn is offered: the worker alone, or hire and worker together")
func toolsListFollowsTheGrants() throws {
    func tools(hiring: Bool, workers: Bool) throws -> [String] {
        let control = ClaudeTextTurnControl()
        var stream = ClaudeTextOnlyStream(request: try textOnlyTestRequest(allowedTools: [.webSearch],
            grantsHiring: hiring, grantsWorkers: workers), control: control)
        try stream.consume(try mcpFrame(id: "list-1", message: ["jsonrpc": "2.0", "id": 1, "method": "tools/list"])) { _ in }
        return try listedTools(try #require(control.takePending().first))
    }
    #expect(try tools(hiring: false, workers: true) == ["spawn_worker"])
    #expect(try tools(hiring: true, workers: true) == ["hire_teammate", "spawn_worker"])
    #expect(try tools(hiring: true, workers: false) == ["hire_teammate"])
}

@Test("A worker call goes to the service keyed to its tool use, is the bot's own only when its reply announced it, and is answered once")
func workerCallsAreAnsweredOnce() throws {
    let request = try textOnlyTestRequest(allowedTools: [.webSearch], grantsWorkers: true)
    let control = ClaudeTextTurnControl()
    var stream = ClaudeTextOnlyStream(request: request, control: control)
    var calls: [ClaudeTextWorkerCall] = []
    var hires = 0
    func consume(_ frame: Data) throws {
        try stream.consume(frame) { event in
            if case .workerRequested(let call) = event { calls.append(call) }
            if case .hireRequested = event { hires += 1 }
        }
    }
    try consume(try textOnlyTestInit(request, override: ["tools": ["AskUserQuestion", "WebSearch", ClaudeTextWorkerPolicy.qualifiedToolName],
        "mcp_servers": [["name": ClaudeTextHirePolicy.serverName, "status": "connected"]], "permissionMode": "default"]))
    try consume(try textOnlyTestReplay(request))
    // The bot's own reply announces the call before the server hears it.
    try consume(try textOnlyTestLine(["type": "assistant", "session_id": request.sessionID.uuidString,
        "message": ["role": "assistant", "model": request.expectedResolvedModel, "content": [
            ["type": "tool_use", "id": "toolu_w1", "name": ClaudeTextWorkerPolicy.qualifiedToolName,
             "input": ["brief": "Summarise the three PDFs in /Users/x/Bot."]]]]]))
    let arguments: [String: Any] = ["brief": "Summarise the three PDFs in /Users/x/Bot."]
    try consume(try mcpFrame(id: "call-1", message: ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
        "params": ["name": "spawn_worker", "arguments": arguments, "_meta": ["claudecode/toolUseId": "toolu_w1"]]]))
    let call = try #require(calls.first)
    #expect(call.requestID == "call-1" && call.toolUseID == "toolu_w1" && call.isOwnCall)
    #expect(try json(call.argumentsJSON) as NSDictionary == arguments as NSDictionary)
    #expect(hires == 0)
    #expect(control.takePending().isEmpty, "a call waits for the service")
    #expect(control.answerWorker(requestID: "call-1", text: "Worker started.", refused: false))
    #expect(!control.answerWorker(requestID: "call-1", text: "again", refused: true), "one answer per call")
    #expect(!control.answerHire(requestID: "call-1", text: "wrong tool", refused: true), "a worker call is never answered as a hire")
    let answer = try #require(try control.takePending().map(json).first)
    let reply = try #require(((answer["response"] as? [String: Any])?["response"] as? [String: Any])?["mcp_response"] as? [String: Any])
    #expect(reply["id"] as? Int == 2)

    // A call nothing announced is not the bot's own.
    try consume(try mcpFrame(id: "call-2", message: ["jsonrpc": "2.0", "id": 3, "method": "tools/call",
        "params": ["name": "spawn_worker", "arguments": arguments, "_meta": ["claudecode/toolUseId": "toolu_w2"]]]))
    #expect(calls.count == 2 && !calls[1].isOwnCall)

    // The CLI gave up on a call: no late answer.
    try consume(try mcpFrame(id: "cancel-1", message: ["jsonrpc": "2.0", "method": "notifications/cancelled",
        "params": ["requestId": 3]]))
    _ = control.takePending()
    #expect(!control.answerWorker(requestID: "call-2", text: "late", refused: false))
}

@Test("A turn not offered the worker refuses its call at once, and the service never hears it")
func workerCallWithoutTheGrantIsRefused() throws {
    let control = ClaudeTextTurnControl()
    var stream = ClaudeTextOnlyStream(request: try textOnlyTestRequest(grantsHiring: true), control: control)
    var events: [ClaudeTextOnlyEvent] = []
    try stream.consume(try mcpFrame(id: "call-1", message: ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
        "params": ["name": "spawn_worker", "arguments": ["brief": "x"], "_meta": ["claudecode/toolUseId": "toolu_w1"]]])) {
        events.append($0)
    }
    #expect(events.isEmpty)
    let answer = try #require(try control.takePending().map(json).first)
    let reply = try #require(((answer["response"] as? [String: Any])?["response"] as? [String: Any])?["mcp_response"] as? [String: Any])
    #expect((reply["result"] as? [String: Any])?["isError"] as? Bool == true)
}

@Test("A worker-holding turn's init frame must announce the worker tool and the app server; a turn without the grant must not")
func workerInitFrameContract() throws {
    let request = try textOnlyTestRequest(allowedTools: [.webSearch], grantsWorkers: true)
    let server: [String: Any] = ["name": ClaudeTextHirePolicy.serverName, "status": "connected"]
    #expect(ClaudeTextOnlyStream.declaredToolsMatch(["AskUserQuestion", "WebSearch", ClaudeTextWorkerPolicy.qualifiedToolName],
        granted: Set(request.grantedToolNames), request: request))
    #expect(!ClaudeTextOnlyStream.declaredToolsMatch(["AskUserQuestion", "WebSearch"],
        granted: Set(request.grantedToolNames), request: request))
    #expect(ClaudeTextOnlyStream.declaredServersMatch([server], request: request))
    let plain = try textOnlyTestRequest(allowedTools: [.webSearch])
    #expect(!ClaudeTextOnlyStream.declaredToolsMatch(["WebSearch", ClaudeTextWorkerPolicy.qualifiedToolName],
        granted: Set(plain.grantedToolNames), request: plain))
}
