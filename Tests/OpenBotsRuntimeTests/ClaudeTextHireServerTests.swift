import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsRuntime

// Bots that hire bots. The carrier is the app's own MCP server,
// `openbots`, over the control channel, with one tool, `hire_teammate` (probed on
// Claude Code 2.1.272). These pin
// the command a hiring turn launches with and the host's answers on the wire.

private func value(_ arguments: [String], _ flag: String) -> String? {
    arguments.firstIndex(of: flag).map { arguments[$0 + 1] }
}

private func json(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func mcpFrame(id: String, message: [String: Any], server: String = ClaudeTextHirePolicy.serverName) throws -> Data {
    try textOnlyTestLine(["type": "control_request", "request_id": id,
                          "request": ["subtype": "mcp_message", "server_name": server, "message": message]])
}

@Test("A hire-only turn launches in the probed connector-turn shape: the channel, the question tool, no safe mode, no server wildcard denied")
func hireOnlyCommandContract() throws {
    let request = try textOnlyTestRequest(grantsHiring: true)
    #expect(request.grantsHiring && request.requiresPermissionControl && request.grantsTools)
    #expect(!request.grantsWork && !request.grantsConnectors)
    #expect(request.grantedToolNames == [ClaudeTextOnlyRequest.questionToolName])
    let arguments = ClaudeTextOnlyCommandBuilder.arguments(for: request)
    #expect(value(arguments, "--tools") == ClaudeTextOnlyRequest.questionToolName)
    #expect(value(arguments, "--permission-mode") == "default")
    #expect(value(arguments, "--permission-prompt-tool") == "stdio")
    #expect(value(arguments, "--max-turns") == "16")
    // The server rides the control channel, not a configuration file.
    #expect(value(arguments, "--mcp-config") == "{\"mcpServers\":{}}")
    #expect(arguments.contains("--strict-mcp-config"))
    #expect(!arguments.contains("--safe-mode"))
    for forbidden in ["--add-dir", "--agents", "--allowedTools"] {
        #expect(!arguments.contains(forbidden), "unexpected \(forbidden)")
    }
    let denied = try #require(value(arguments, "--disallowedTools")).split(separator: ",").map(String.init)
    #expect(!denied.contains("mcp__*"), "the wildcard would shadow the hire tool")
    #expect(!denied.contains("*"))
    for name in ["Agent", "Task", "Bash", "Read", "WebFetch", "WebSearch", "Skill"] {
        #expect(denied.contains(name), "missing deny \(name)")
    }
    // The probed command, flag for flag where the app's own flags decide.
    #expect(denied == ClaudeTextOnlyCommandBuilder.deniableToolNames.filter { $0 != "AskUserQuestion" && $0 != "mcp__*" })

    let settings = try json(Data(ClaudeTextOnlyCommandBuilder.settingsJSON(for: request).utf8))
    let permissions = try #require(settings["permissions"] as? [String: Any])
    #expect(permissions["defaultMode"] as? String == "default")
    // The exact name, from its own constant, and nothing else: the switch is
    // the user's authorization, so the call reaches the app without a card.
    #expect(permissions["allow"] as? [String] == ["mcp__openbots__hire_teammate"])
    #expect((permissions["deny"] as? [String]) == denied)
    #expect(settings["sandbox"] == nil)
    #expect(ClaudeTextHirePolicy.qualifiedToolName == "mcp__\(ClaudeTextHirePolicy.serverName)__\(ClaudeTextHirePolicy.toolName)")
}

@Test("Work and hiring together keep the work settings, add only the hire name to allow, and leave the helper unable to hire")
func workWithHiringKeepsTheHelperFenced() throws {
    let work = try ClaudeTextWorkAccess(workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/desk.noindex"),
                                        protectedPaths: ["/Users/x/.ssh"])
    let request = try textOnlyTestRequest(allowedTools: [.webSearch], workAccess: work, grantsHiring: true)
    let withoutHiring = try textOnlyTestRequest(allowedTools: [.webSearch], workAccess: work)
    let arguments = ClaudeTextOnlyCommandBuilder.arguments(for: request)
    #expect(value(arguments, "--tools") == value(ClaudeTextOnlyCommandBuilder.arguments(for: withoutHiring), "--tools"))
    let denied = try #require(value(arguments, "--disallowedTools")).split(separator: ",").map(String.init)
    #expect(!denied.contains("mcp__*"))
    let settings = try json(Data(ClaudeTextOnlyCommandBuilder.settingsJSON(for: request).utf8))
    let permissions = try #require(settings["permissions"] as? [String: Any])
    #expect(permissions["allow"] as? [String] == ["WebSearch", "mcp__openbots__hire_teammate"])
    #expect(permissions["ask"] as? [String] == ["Agent"])
    #expect(settings["sandbox"] != nil)
    // The helper's own tools list is the fence (probed): unchanged, it
    // neither names the hire tool nor drops the server wildcard.
    let helpers = try json(Data(try #require(value(arguments, "--agents")).utf8))
    let helper = try #require(helpers[ClaudeTextHelperPolicy.agentType] as? [String: Any])
    #expect(!(helper["tools"] as? [String] ?? []).contains(ClaudeTextHirePolicy.qualifiedToolName))
    #expect((helper["disallowedTools"] as? [String] ?? []).contains("mcp__*"))
    #expect(value(arguments, "--agents") == value(ClaudeTextOnlyCommandBuilder.arguments(for: withoutHiring), "--agents"))
}

/// The shape a bot with Gmail, Messages or Control this Mac and the hire switch
/// launches: the connector's servers from the configuration file, the hire
/// server over the channel, one settings allow list and two deny lists.
@Test("A connector turn with the hire grant allows the web tools and the hire name, denies no server wildcard on either list, and its helper still cannot hire")
func connectorBesideHireCommand() throws {
    let access = try connectorAccessFixture()
    let hire = ClaudeTextHirePolicy.qualifiedToolName
    // Without Work: the connector turn's own shape, the hire name added.
    let request = try textOnlyTestRequest(allowedTools: [.webSearch], connectorAccess: access, grantsHiring: true)
    #expect(request.grantsConnectors && request.grantsHiring && request.requiresPermissionControl)
    let arguments = ClaudeTextOnlyCommandBuilder.arguments(for: request)
    #expect(value(arguments, "--mcp-config") == ClaudeTextConnectorConfigurationFile.configurationURL(for: request).path)
    #expect(value(arguments, "--tools") == "AskUserQuestion,WebSearch")
    #expect(!arguments.contains("--agents"))
    let denied = try #require(value(arguments, "--disallowedTools")).split(separator: ",").map(String.init)
    #expect(!denied.contains("mcp__*"), "the wildcard would shadow both the connector and the hire tool")
    #expect(!denied.contains(hire))
    let settings = try json(Data(ClaudeTextOnlyCommandBuilder.settingsJSON(for: request).utf8))
    let permissions = try #require(settings["permissions"] as? [String: Any])
    #expect(permissions["defaultMode"] as? String == "default")
    #expect(permissions["allow"] as? [String] == ["WebSearch", hire], "no connector tool is ever allowed by rule")
    #expect(permissions["deny"] as? [String] == denied)

    // With Work too: the work settings, and the helper's own tool list names no server tool.
    let work = try ClaudeTextWorkAccess(workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/desk.noindex"), protectedPaths: [])
    let working = try textOnlyTestRequest(allowedTools: [.webSearch], workAccess: work, connectorAccess: access, grantsHiring: true)
    let workArguments = ClaudeTextOnlyCommandBuilder.arguments(for: working)
    let workDenied = try #require(value(workArguments, "--disallowedTools")).split(separator: ",").map(String.init)
    #expect(!workDenied.contains("mcp__*"))
    let workSettings = try json(Data(ClaudeTextOnlyCommandBuilder.settingsJSON(for: working).utf8))
    let workPermissions = try #require(workSettings["permissions"] as? [String: Any])
    #expect(workPermissions["allow"] as? [String] == ["WebSearch", hire])
    #expect(!(workPermissions["deny"] as? [String] ?? []).contains("mcp__*"))
    let helpers = try json(Data(try #require(value(workArguments, "--agents")).utf8))
    let helper = try #require(helpers[ClaudeTextHelperPolicy.agentType] as? [String: Any])
    let helperTools = try #require(helper["tools"] as? [String])
    #expect(!helperTools.contains(hire))
    #expect(!helperTools.contains { $0.hasPrefix("mcp__") })
}

@Test("A connector turn with the hire grant accepts an init frame naming both servers and both tool sets, and refuses one missing either")
func connectorBesideHireInitFrame() throws {
    let access = try connectorAccessFixture()
    let server = try #require(access.servers.first).name
    let request = try textOnlyTestRequest(connectorAccess: access, grantsHiring: true)
    let connectorTools = ["mcp__\(server)__click", "mcp__\(server)__navigate_page"]
    let hire = ClaudeTextHirePolicy.qualifiedToolName
    let connector: [String: Any] = ["name": server, "status": "connected"]
    let hireServer: [String: Any] = ["name": ClaudeTextHirePolicy.serverName, "status": "connected"]
    func initialize(tools: [String], servers: [[String: Any]]) throws -> [ClaudeTextOnlyEvent] {
        var stream = ClaudeTextOnlyStream(request: request, control: ClaudeTextTurnControl())
        var events: [ClaudeTextOnlyEvent] = []
        try stream.consume(try textOnlyTestInit(request, override: [
            "tools": tools, "mcp_servers": servers, "permissionMode": "default"])) { events.append($0) }
        return events
    }
    let whole = ["AskUserQuestion", hire] + connectorTools
    #expect(try initialize(tools: whole, servers: [connector, hireServer])
        == [.initialized(sessionID: request.sessionID, actualModel: request.expectedResolvedModel)])
    #expect(try initialize(tools: Array(whole.reversed()), servers: [hireServer, connector]).count == 1, "order is not the fence")

    let servers = ClaudeTextOnlyRejection(failure: .unsafeInitialization, code: .initializationMCPInvalid)
    let tools = ClaudeTextOnlyRejection(failure: .unsafeInitialization, code: .initializationToolsInvalid)
    #expect(throws: servers, "the hire server missing") { try initialize(tools: whole, servers: [connector]) }
    #expect(throws: servers, "the connector's server missing") { try initialize(tools: whole, servers: [hireServer]) }
    #expect(throws: tools, "the hire tool missing") { try initialize(tools: ["AskUserQuestion"] + connectorTools, servers: [connector, hireServer]) }
    #expect(throws: tools, "the connector's tools missing") { try initialize(tools: ["AskUserQuestion", hire], servers: [connector, hireServer]) }
}

@Test("A turn without the hire grant launches byte for byte as before, and its handshake names no server")
func noHiringIsTheShippedCommand() throws {
    let work = try ClaudeTextWorkAccess(workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/desk.noindex"), protectedPaths: [])
    for request in [try textOnlyTestRequest(), try textOnlyTestRequest(allowedTools: [.webFetch]),
                    try textOnlyTestRequest(workAccess: work)] {
        #expect(!request.grantsHiring)
        let settings = ClaudeTextOnlyCommandBuilder.settingsJSON(for: request)
        #expect(!settings.contains("hire_teammate"))
        #expect(!ClaudeTextOnlyCommandBuilder.arguments(for: request).joined(separator: " ").contains("hire_teammate"))
    }
    let plain = try ClaudeTextOnlyCommandBuilder.initializeControlRecord(id: "id-1", appServer: false)
    #expect(String(decoding: plain, as: UTF8.self)
        == "{\"request\":{\"hooks\":{},\"subtype\":\"initialize\"},\"request_id\":\"id-1\",\"type\":\"control_request\"}\n")
    let hiring = try ClaudeTextOnlyCommandBuilder.initializeControlRecord(id: "id-1", appServer: true)
    #expect(String(decoding: hiring, as: UTF8.self)
        == "{\"request\":{\"hooks\":{},\"sdkMcpServerConfigs\":{\"openbots\":{\"timeout\":60000}},\"sdkMcpServers\":[\"openbots\"],\"subtype\":\"initialize\"},\"request_id\":\"id-1\",\"type\":\"control_request\"}\n")
}

@Test("The tool the server lists takes exactly the hire request's fields, the handle and purpose required, all text")
func toolDefinitionMatchesTheRequest() throws {
    let tool = ClaudeTextHirePolicy.toolDefinition
    #expect(tool["name"] as? String == "hire_teammate")
    #expect(!(tool["description"] as? String ?? "").isEmpty)
    let schema = try #require(tool["inputSchema"] as? [String: Any])
    #expect(schema["type"] as? String == "object")
    #expect(schema["additionalProperties"] as? Bool == false)
    #expect(schema["required"] as? [String] == ["handle", "purpose"])
    let properties = try #require(schema["properties"] as? [String: [String: Any]])
    #expect(Set(properties.keys) == Set(TeammateHireRequest.fieldNames))
    for (name, property) in properties {
        #expect(property["type"] as? String == "string", "\(name) is not text")
        #expect(!(property["description"] as? String ?? "").isEmpty, "\(name) says nothing")
    }
}

@Test("The host answers the handshake, a notification, the tool list and an unknown method at once, each exactly once, never with an empty answer")
func handshakeAnswers() throws {
    let control = ClaudeTextTurnControl()
    var stream = ClaudeTextOnlyStream(request: try textOnlyTestRequest(grantsHiring: true), control: control)
    stream.expectControlInitialization(requestID: "control-1")
    var events: [ClaudeTextOnlyEvent] = []
    // All before the init frame, as the CLI sends them.
    try stream.consume(try mcpFrame(id: "m-1", message: ["jsonrpc": "2.0", "id": 0, "method": "initialize",
        "params": ["protocolVersion": "2025-11-25", "capabilities": [String: Any](),
                   "clientInfo": ["name": "claude-code", "version": "2.1.272"]]])) { events.append($0) }
    try stream.consume(try mcpFrame(id: "m-2", message: ["jsonrpc": "2.0", "method": "notifications/initialized"])) { events.append($0) }
    try stream.consume(try mcpFrame(id: "m-3", message: ["jsonrpc": "2.0", "id": 1, "method": "tools/list"])) { events.append($0) }
    try stream.consume(try mcpFrame(id: "m-4", message: ["jsonrpc": "2.0", "id": 7, "method": "resources/list"])) { events.append($0) }
    #expect(events.isEmpty, "nothing here is the service's business")
    let answers = try control.takePending().map(json)
    #expect(answers.count == 4)
    #expect(control.takePending().isEmpty, "each answer is written once")
    func mcpResponse(_ answer: [String: Any], requestID: String) throws -> [String: Any] {
        #expect(answer["type"] as? String == "control_response")
        let response = try #require(answer["response"] as? [String: Any])
        #expect(response["subtype"] as? String == "success")
        #expect(response["request_id"] as? String == requestID)
        let body = try #require(response["response"] as? [String: Any])
        #expect(Set(body.keys) == ["mcp_response"], "an answer without mcp_response is silence to the CLI")
        let reply = try #require(body["mcp_response"] as? [String: Any])
        #expect(reply["jsonrpc"] as? String == "2.0")
        return reply
    }
    let initialize = try mcpResponse(answers[0], requestID: "m-1")
    #expect(initialize["id"] as? Int == 0)
    let result = try #require(initialize["result"] as? [String: Any])
    #expect(result["protocolVersion"] as? String == "2025-11-25")
    #expect((result["capabilities"] as? [String: Any])?["tools"] != nil)
    #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "openbots")
    let notification = try mcpResponse(answers[1], requestID: "m-2")
    #expect(notification["id"] as? Int == 0)
    #expect((notification["result"] as? [String: Any])?.isEmpty == true)
    let list = try mcpResponse(answers[2], requestID: "m-3")
    #expect(list["id"] as? Int == 1)
    let tools = try #require((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
    #expect(tools.map { $0["name"] as? String } == ["hire_teammate"])
    let unknown = try mcpResponse(answers[3], requestID: "m-4")
    #expect(unknown["id"] as? Int == 7)
    #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32601)
}

@Test("A hire call goes to the service keyed to its tool use, is answered once, and a call the CLI gave up on gets no late answer")
func callsAreAnsweredOnce() throws {
    let control = ClaudeTextTurnControl()
    var stream = ClaudeTextOnlyStream(request: try textOnlyTestRequest(grantsHiring: true), control: control)
    var calls: [ClaudeTextHireCall] = []
    func consume(_ frame: Data) throws {
        try stream.consume(frame) { event in if case .hireRequested(let call) = event { calls.append(call) } }
    }
    let arguments: [String: Any] = ["handle": "scout", "purpose": "Price watching"]
    try consume(try mcpFrame(id: "call-1", message: ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
        "params": ["name": "hire_teammate", "arguments": arguments,
                   "_meta": ["claudecode/toolUseId": "toolu_01", "progressToken": 2]]]))
    let call = try #require(calls.first)
    #expect(call.requestID == "call-1")
    #expect(call.toolUseID == "toolu_01")
    #expect(try json(call.argumentsJSON) as NSDictionary == arguments as NSDictionary)
    #expect(!call.isOwnCall, "no reply of the bot's own announced this tool use")
    #expect(control.takePending().isEmpty, "a call waits for the service")

    #expect(control.answerHire(requestID: "call-1", text: "Hired @scout: Price watching.", refused: false))
    #expect(!control.answerHire(requestID: "call-1", text: "again", refused: true), "one answer per call")
    let answer = try #require(try control.takePending().map(json).first)
    let reply = try #require(((answer["response"] as? [String: Any])?["response"] as? [String: Any])?["mcp_response"] as? [String: Any])
    #expect(reply["id"] as? Int == 2)
    let result = try #require(reply["result"] as? [String: Any])
    #expect(result["isError"] == nil)
    #expect((result["content"] as? [[String: Any]])?.first?["text"] as? String == "Hired @scout: Price watching.")

    // A refusal is a result the model reads, flagged as an error.
    try consume(try mcpFrame(id: "call-2", message: ["jsonrpc": "2.0", "id": 3, "method": "tools/call",
        "params": ["name": "hire_teammate", "arguments": arguments, "_meta": ["claudecode/toolUseId": "toolu_02"]]]))
    #expect(control.answerHire(requestID: "call-2", text: "Hire refused: hiring is switched off for this bot.", refused: true))
    let refusal = try #require(try control.takePending().map(json).first)
    let refused = try #require(((refusal["response"] as? [String: Any])?["response"] as? [String: Any])?["mcp_response"] as? [String: Any])
    #expect((refused["result"] as? [String: Any])?["isError"] as? Bool == true)

    // The CLI timed a call out and said so: the notification is answered at
    // once, and the answer the service makes afterwards is never written.
    try consume(try mcpFrame(id: "call-3", message: ["jsonrpc": "2.0", "id": 4, "method": "tools/call",
        "params": ["name": "hire_teammate", "arguments": arguments, "_meta": ["claudecode/toolUseId": "toolu_03"]]]))
    try consume(try mcpFrame(id: "cancel-1", message: ["jsonrpc": "2.0", "method": "notifications/cancelled",
        "params": ["requestId": 4, "reason": "McpError: MCP error -32001: Request timed out"]]))
    #expect(try control.takePending().map(json).count == 1, "the notification's own answer")
    #expect(!control.answerHire(requestID: "call-3", text: "Hired @scout.", refused: false))
    #expect(control.takePending().isEmpty)
    #expect(calls.count == 3)

    // A call for a tool the server does not list is refused at once and never reaches the service.
    try consume(try mcpFrame(id: "call-4", message: ["jsonrpc": "2.0", "id": 5, "method": "tools/call",
        "params": ["name": "fire_teammate", "arguments": arguments, "_meta": ["claudecode/toolUseId": "toolu_04"]]]))
    #expect(calls.count == 3)
    let other = try #require(try control.takePending().map(json).first)
    let otherReply = try #require(((other["response"] as? [String: Any])?["response"] as? [String: Any])?["mcp_response"] as? [String: Any])
    #expect((otherReply["result"] as? [String: Any])?["isError"] as? Bool == true)
}

/// A cancellation names a call by its JSON-RPC id only, and the ids start
/// again after the CLI reconnects the server (probed: a second
/// handshake round). A call from the connection before is one the CLI no
/// longer waits for.
@Test("A fresh initialize ends the calls of the connection before it, so a cancellation afterwards reaches only the new connection's call")
func aFreshInitializeEndsEarlierCalls() throws {
    let control = ClaudeTextTurnControl()
    var stream = ClaudeTextOnlyStream(request: try textOnlyTestRequest(grantsHiring: true), control: control)
    var calls: [ClaudeTextHireCall] = []
    func consume(_ frame: Data) throws {
        try stream.consume(frame) { event in if case .hireRequested(let call) = event { calls.append(call) } }
    }
    let initialize: [String: Any] = ["jsonrpc": "2.0", "id": 0, "method": "initialize"]
    func call(_ toolUseID: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
         "params": ["name": "hire_teammate", "arguments": ["handle": "scout", "purpose": "Prices"],
                    "_meta": ["claudecode/toolUseId": toolUseID]]]
    }
    try consume(try mcpFrame(id: "init-1", message: initialize))
    try consume(try mcpFrame(id: "call-old", message: call("toolu_old")))
    // The CLI reconnects the server: a new handshake, and its JSON-RPC ids start again.
    try consume(try mcpFrame(id: "init-2", message: initialize))
    try consume(try mcpFrame(id: "call-new", message: call("toolu_new")))
    #expect(calls.map(\.toolUseID) == ["toolu_old", "toolu_new"])
    _ = control.takePending()
    #expect(!control.answerHire(requestID: "call-old", text: "Hired @scout.", refused: false),
            "no answer goes to a call the reconnected CLI no longer waits for")
    try consume(try mcpFrame(id: "cancel-1", message: ["jsonrpc": "2.0", "method": "notifications/cancelled",
                                                      "params": ["requestId": 2, "reason": "timed out"]]))
    #expect(!control.answerHire(requestID: "call-new", text: "Hired @scout.", refused: false))
    #expect(control.takePending().count == 1, "the notification's own answer, and nothing else")
}

@Test("The server's messages are refused on a turn without the grant, for another server, twice under one id, or past their bound")
func messagesAreFenced() throws {
    let initialize: [String: Any] = ["jsonrpc": "2.0", "id": 0, "method": "initialize"]
    // No grant: the shipped guard, unchanged.
    var ungranted = ClaudeTextOnlyStream(request: try textOnlyTestRequest(connectorAccess: try connectorAccessFixture()),
                                         control: ClaudeTextTurnControl())
    #expect(throws: ClaudeTextOnlyRejection(failure: .invalidStream, code: .unexpectedEvent)) {
        try ungranted.consume(try mcpFrame(id: "m-1", message: initialize)) { _ in }
    }
    // Another server name.
    var granted = ClaudeTextOnlyStream(request: try textOnlyTestRequest(grantsHiring: true), control: ClaudeTextTurnControl())
    #expect(throws: ClaudeTextOnlyRejection(failure: .invalidStream, code: .unexpectedEvent)) {
        try granted.consume(try mcpFrame(id: "m-1", message: initialize, server: "openbots_other")) { _ in }
    }
    // The same request id twice.
    var twice = ClaudeTextOnlyStream(request: try textOnlyTestRequest(grantsHiring: true), control: ClaudeTextTurnControl())
    try twice.consume(try mcpFrame(id: "m-1", message: initialize)) { _ in }
    #expect(throws: ClaudeTextOnlyRejection(failure: .invalidStream, code: .unexpectedEvent)) {
        try twice.consume(try mcpFrame(id: "m-1", message: initialize)) { _ in }
    }
    // Not JSON-RPC 2.0, or a call with no tool use to key it to.
    var malformed = ClaudeTextOnlyStream(request: try textOnlyTestRequest(grantsHiring: true), control: ClaudeTextTurnControl())
    #expect(throws: ClaudeTextOnlyRejection(failure: .invalidStream, code: .unexpectedEvent)) {
        try malformed.consume(try mcpFrame(id: "m-1", message: ["jsonrpc": "1.0", "id": 0, "method": "initialize"])) { _ in }
    }
    var unkeyed = ClaudeTextOnlyStream(request: try textOnlyTestRequest(grantsHiring: true), control: ClaudeTextTurnControl())
    #expect(throws: ClaudeTextOnlyRejection(failure: .invalidStream, code: .unexpectedEvent)) {
        try unkeyed.consume(try mcpFrame(id: "m-1", message: ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": ["name": "hire_teammate", "arguments": ["handle": "scout"]]])) { _ in }
    }
    // A bounded number of messages per turn.
    let control = ClaudeTextTurnControl()
    var flood = ClaudeTextOnlyStream(request: try textOnlyTestRequest(grantsHiring: true), control: control)
    for index in 0..<ClaudeTextOnlyStream.maximumHireServerMessages {
        try flood.consume(try mcpFrame(id: "m-\(index)", message: ["jsonrpc": "2.0", "method": "notifications/progress"])) { _ in }
    }
    #expect(throws: ClaudeTextOnlyRejection(failure: .invalidStream, code: .unexpectedEvent)) {
        try flood.consume(try mcpFrame(id: "m-last", message: ["jsonrpc": "2.0", "method": "notifications/progress"])) { _ in }
    }
    #expect(control.takePending().count == ClaudeTextOnlyStream.maximumHireServerMessages)
}

@Test("A hiring turn's echo bound grows by the server's own budget; a turn without hiring keeps the reviewed bound")
func echoBoundGrowsWithTheServer() throws {
    // Every success answer the host writes comes back as an echo, so a
    // hiring turn's handshake, calls and cancellations must never eat the
    // room its questions' echoes had.
    func echo(_ index: Int) throws -> Data {
        try textOnlyTestLine(["type": "control_response",
                              "response": ["subtype": "success", "request_id": "echo-\(index)", "response": [String: Any]()]])
    }
    let refusal = ClaudeTextOnlyRejection(failure: .invalidStream, code: .unexpectedEvent)
    var hiring = ClaudeTextOnlyStream(request: try textOnlyTestRequest(grantsHiring: true), control: ClaudeTextTurnControl())
    let grown = ClaudeTextOnlyStream.maximumControlEchoes + ClaudeTextOnlyStream.maximumHireServerMessages
    #expect(grown == 128)
    for index in 0..<grown { try hiring.consume(try echo(index)) { _ in } }
    #expect(throws: refusal) { try hiring.consume(try echo(grown)) { _ in } }

    var browsing = ClaudeTextOnlyStream(request: try textOnlyTestRequest(connectorAccess: try connectorAccessFixture()),
                                        control: ClaudeTextTurnControl())
    for index in 0..<ClaudeTextOnlyStream.maximumControlEchoes { try browsing.consume(try echo(index)) { _ in } }
    #expect(throws: refusal) { try browsing.consume(try echo(ClaudeTextOnlyStream.maximumControlEchoes)) { _ in } }
}

private func hireProcessEmit(_ data: Data) throws -> String {
    let text = try #require(String(data: data, encoding: .utf8))
    return "/bin/cat <<'OPENBOTS_SYNTHETIC_EVENT'\n" + text + "OPENBOTS_SYNTHETIC_EVENT"
}

private actor HireProcessEvents {
    private var values: [ClaudeTextOnlyEvent] = []
    func append(_ event: ClaudeTextOnlyEvent) { values.append(event) }
    func snapshot() -> [ClaudeTextOnlyEvent] { values }
}

@Test("A synthetic hiring child gets the handshake naming the server, asks for its server before acknowledging it, and reads every answer, the call's included, on its still-open stdin")
func hireProcessRoundTrip() async throws {
    let template = try textOnlyTestRequest(grantsHiring: true)
    let server: (String, [String: Any]) throws -> Data = { id, message in
        try textOnlyTestLine(["type": "control_request", "request_id": id,
            "request": ["subtype": "mcp_message", "server_name": "openbots", "message": message]])
    }
    let initialize = try server("m-1", ["jsonrpc": "2.0", "id": 0, "method": "initialize",
        "params": ["protocolVersion": "2025-11-25", "capabilities": [String: Any]()]])
    let list = try server("m-2", ["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
    let initFrame = try textOnlyTestInit(template, override: [
        "tools": ["AskUserQuestion", ClaudeTextHirePolicy.qualifiedToolName],
        "mcp_servers": [["name": "openbots", "status": "connected"]], "permissionMode": "default"])
    let arguments: [String: Any] = ["handle": "Scout", "purpose": "Price watching"]
    let announcement = try textOnlyTestLine(["type": "assistant", "session_id": template.sessionID.uuidString,
        "message": ["role": "assistant", "model": template.expectedResolvedModel,
                    "content": [["type": "tool_use", "id": "toolu_1", "name": ClaudeTextHirePolicy.qualifiedToolName, "input": arguments]]]])
    let call = try server("m-3", ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
        "params": ["name": "hire_teammate", "arguments": arguments,
                   "_meta": ["claudecode/toolUseId": "toolu_1", "progressToken": 2]]])
    let toolResult = try textOnlyTestLine(["type": "user", "session_id": template.sessionID.uuidString,
        "parent_tool_use_id": NSNull(),
        "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_1",
                                                 "content": [["type": "text", "text": "Hired @Scout"]]]]]])
    let fixture = try ClaudeConnectionFixture(body: """
    printf '%s\\n' "$@" > argv-observed
    IFS= read -r handshake
    printf '%s\\n' "$handshake" > handshake-observed
    case "$handshake" in *'"sdkMcpServers":["openbots"]'*) ;; *) exit 41 ;; esac
    case "$handshake" in *'"sdkMcpServerConfigs":{"openbots":{"timeout":60000}}'*) ;; *) exit 42 ;; esac
    request_id=$(printf '%s' "$handshake" | /usr/bin/sed -n 's/.*"request_id":"\\([^"]*\\)".*/\\1/p')
    \(try hireProcessEmit(initialize))
    IFS= read -r line
    IFS= read -r answer
    printf '%s\\n' "$answer" > initialize-answer
    case "$answer" in *'"request_id":"m-1"'*'"mcp_response"'*) ;; *) exit 43 ;; esac
    printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{}}}\\n' "$request_id"
    \(try hireProcessEmit(list))
    IFS= read -r answer
    case "$answer" in *'"request_id":"m-2"'*'"hire_teammate"'*) ;; *) exit 44 ;; esac
    \(try hireProcessEmit(initFrame))
    printf '{"isReplay":true,"parent_tool_use_id":null,%s\\n' "${line#?}"
    \(try hireProcessEmit(announcement))
    \(try hireProcessEmit(call))
    IFS= read -r answer
    printf '%s\\n' "$answer" > call-answer
    case "$answer" in *'"request_id":"m-3"'*'Hired @Scout'*) ;; *) exit 45 ;; esac
    \(try hireProcessEmit(toolResult))
    \(try hireProcessEmit(textOnlyTestDelta(template, text: "Scout is hired.")))
    \(try hireProcessEmit(textOnlyTestResult(template, override: ["result": "Scout is hired."])))
    if IFS= read -r extra; then exit 46; fi
    """)
    defer { fixture.remove() }
    let request = try textOnlyTestRequest(target: fixture.target, grantsHiring: true)
    let control = ClaudeTextTurnControl()
    let events = HireProcessEvents()
    let result = await NativeClaudeTextOnlyRunner().run(request: request, control: control) { event in
        await events.append(event)
        if case .hireRequested(let hire) = event {
            control.answerHire(requestID: hire.requestID, text: "Hired @Scout: Price watching.", refused: false)
        }
    }
    #expect(result == .success(.init(sessionID: request.sessionID, actualModel: "claude-sonnet-5",
        text: "Scout is hired.", confirmedActualModel: "claude-sonnet-5")))
    let observed = await events.snapshot()
    #expect(observed.contains(.controlReady))
    let hires = observed.compactMap { if case .hireRequested(let hire) = $0 { return hire }; return nil }
    #expect(hires.map(\.toolUseID) == ["toolu_1"])
    #expect(hires.first?.isOwnCall == true)
    let initializeAnswer = try fixture.readWorkingFile("initialize-answer")
    #expect(initializeAnswer.contains("\"protocolVersion\":\"2025-11-25\""))
    let callAnswer = try fixture.readWorkingFile("call-answer")
    #expect(callAnswer.contains("\"id\":2") && !callAnswer.contains("isError"))
    let arguments2 = try fixture.readWorkingFile("argv-observed")
    #expect(arguments2.contains("--permission-prompt-tool\nstdio"))
    #expect(arguments2.contains("--tools\nAskUserQuestion\n"))
}

// MARK: - The login handoff

// A bot on Control this Mac hands the user the screen with `hand_over_screen`, on the
// same app server. It is never allowed ahead: its permission request is the card.

private func screenHandoffRequest(grantsHiring: Bool = false) throws -> ClaudeTextOnlyRequest {
    let server = try ClaudeTextConnectorServer(name: "openbots_mac", role: .macControl,
        program: .installedTool(URL(fileURLWithPath: "/private/tmp/openbots-peekaboo-fixture")), options: [], environment: [:])
    return try textOnlyTestRequest(connectorAccess: try ClaudeTextConnectorAccess(servers: [server]), grantsHiring: grantsHiring)
}

@Test("A Control this Mac turn carries the app server with the handoff tool alone, asks about it rather than allowing it, and opens the server in its handshake")
func controlThisMacCarriesTheHandoffTool() throws {
    let request = try screenHandoffRequest()
    #expect(request.grantsScreenHandoff && request.carriesAppServer && !request.grantsHiring)
    #expect(request.appServerToolNames == [ClaudeTextScreenHandoffPolicy.qualifiedToolName])
    #expect(ClaudeTextScreenHandoffPolicy.qualifiedToolName
        == "mcp__\(ClaudeTextScreenHandoffPolicy.serverName)__\(ClaudeTextScreenHandoffPolicy.toolName)")
    let settings = try json(Data(ClaudeTextOnlyCommandBuilder.settingsJSON(for: request).utf8))
    let permissions = try #require(settings["permissions"] as? [String: Any])
    let allowed = permissions["allow"] as? [String] ?? []
    #expect(!allowed.contains(ClaudeTextScreenHandoffPolicy.qualifiedToolName), "allowed ahead, it would never be a card")
    #expect(!allowed.contains { $0.hasPrefix("mcp__openbots_mac") }, "no Control this Mac tool is allowed ahead")
    let arguments = ClaudeTextOnlyCommandBuilder.arguments(for: request)
    #expect(!(value(arguments, "--allowedTools") ?? "").contains("hand_over_screen"))
    // Beside hiring, both tools, and only the hire tool is allowed ahead.
    let both = try screenHandoffRequest(grantsHiring: true)
    #expect(both.appServerToolNames == [ClaudeTextHirePolicy.qualifiedToolName, ClaudeTextScreenHandoffPolicy.qualifiedToolName])
    let bothPermissions = try #require(try json(Data(ClaudeTextOnlyCommandBuilder.settingsJSON(for: both).utf8))["permissions"] as? [String: Any])
    #expect(!(bothPermissions["allow"] as? [String] ?? []).contains(ClaudeTextScreenHandoffPolicy.qualifiedToolName))
    // A connector turn without Control this Mac carries no server of the app's.
    let browser = try textOnlyTestRequest(connectorAccess: try connectorAccessFixture())
    #expect(!browser.grantsScreenHandoff && !browser.carriesAppServer && browser.appServerToolNames.isEmpty)
}

@Test("A Control this Mac turn's init frame must announce the handoff tool and the app server, and a turn without it must not")
func handoffToolIsAnnouncedExactlyWhenCarried() throws {
    let request = try screenHandoffRequest()
    let handoff = ClaudeTextScreenHandoffPolicy.qualifiedToolName
    let mac: [String: Any] = ["name": "openbots_mac", "status": "connected"]
    let app: [String: Any] = ["name": ClaudeTextHirePolicy.serverName, "status": "connected"]
    func initialize(_ request: ClaudeTextOnlyRequest, tools: [String], servers: [[String: Any]]) throws -> [ClaudeTextOnlyEvent] {
        var stream = ClaudeTextOnlyStream(request: request, control: ClaudeTextTurnControl())
        var events: [ClaudeTextOnlyEvent] = []
        try stream.consume(try textOnlyTestInit(request, override: [
            "tools": tools, "mcp_servers": servers, "permissionMode": "default"])) { events.append($0) }
        return events
    }
    let whole = ["AskUserQuestion", handoff, "mcp__openbots_mac__see"]
    #expect(try initialize(request, tools: whole, servers: [mac, app]).count == 1)
    let servers = ClaudeTextOnlyRejection(failure: .unsafeInitialization, code: .initializationMCPInvalid)
    let tools = ClaudeTextOnlyRejection(failure: .unsafeInitialization, code: .initializationToolsInvalid)
    #expect(throws: tools, "the handoff tool missing") {
        try initialize(request, tools: ["AskUserQuestion", "mcp__openbots_mac__see"], servers: [mac, app]) }
    #expect(throws: servers, "the app server missing") { try initialize(request, tools: whole, servers: [mac]) }
    #expect(throws: tools, "the hire tool on a turn without hiring") {
        try initialize(request, tools: whole + [ClaudeTextHirePolicy.qualifiedToolName], servers: [mac, app]) }
    // A hire-only turn never announces the handoff.
    let hireOnly = try textOnlyTestRequest(grantsHiring: true)
    #expect(throws: tools, "the handoff tool on a turn without Control this Mac") {
        try initialize(hireOnly, tools: ["AskUserQuestion", ClaudeTextHirePolicy.qualifiedToolName, handoff], servers: [app]) }
}

@Test("The app server lists the handoff tool on a Control this Mac turn, answers its call at once with the hand-back sentence, and lists no hire tool there")
func handoffServerAnswers() throws {
    let control = ClaudeTextTurnControl()
    var stream = ClaudeTextOnlyStream(request: try screenHandoffRequest(), control: control)
    var events: [ClaudeTextOnlyEvent] = []
    // The user handed back on toolu_02's card; nobody did on toolu_04's.
    control.handBackScreen(toolUseID: "toolu_02")
    try stream.consume(try mcpFrame(id: "m-1", message: ["jsonrpc": "2.0", "id": 1, "method": "tools/list"])) { events.append($0) }
    try stream.consume(try mcpFrame(id: "m-2", message: ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
        "params": ["name": "hand_over_screen", "arguments": ["reason": "Sign in to your Apple Account in Safari."],
                   "_meta": ["claudecode/toolUseId": "toolu_02", "progressToken": 2]]])) { events.append($0) }
    try stream.consume(try mcpFrame(id: "m-3", message: ["jsonrpc": "2.0", "id": 3, "method": "tools/call",
        "params": ["name": "hire_teammate", "arguments": ["handle": "scout", "purpose": "x"],
                   "_meta": ["claudecode/toolUseId": "toolu_03", "progressToken": 3]]])) { events.append($0) }
    try stream.consume(try mcpFrame(id: "m-4", message: ["jsonrpc": "2.0", "id": 4, "method": "tools/call",
        "params": ["name": "hand_over_screen", "arguments": ["reason": "Sign in."],
                   "_meta": ["claudecode/toolUseId": "toolu_04", "progressToken": 4]]])) { events.append($0) }
    #expect(events.isEmpty, "no hire call reaches the service from a turn without hiring")
    let answers = try control.takePending().map(json)
    #expect(answers.count == 4)
    func reply(_ answer: [String: Any]) throws -> [String: Any] {
        try #require(((answer["response"] as? [String: Any])?["response"] as? [String: Any])?["mcp_response"] as? [String: Any])
    }
    let listed = try #require((try reply(answers[0])["result"] as? [String: Any])?["tools"] as? [[String: Any]])
    #expect(listed.map { $0["name"] as? String } == ["hand_over_screen"])
    let schema = try #require(listed.first?["inputSchema"] as? [String: Any])
    #expect(schema["required"] as? [String] == ["reason"])
    #expect(schema["additionalProperties"] as? Bool == false)
    let handedBack = try #require(try reply(answers[1])["result"] as? [String: Any])
    #expect(handedBack["isError"] == nil)
    #expect(((handedBack["content"] as? [[String: Any]])?.first?["text"] as? String) == ClaudeTextScreenHandoffPolicy.handedBackResult)
    let refused = try #require(try reply(answers[2])["result"] as? [String: Any])
    #expect(refused["isError"] as? Bool == true)
    #expect((((refused["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "").contains("hand_over_screen"))
    // A call no card of the user's handed back is never told that they did.
    let unasked = try #require(try reply(answers[3])["result"] as? [String: Any])
    #expect(unasked["isError"] as? Bool == true)
    #expect(((unasked["content"] as? [[String: Any]])?.first?["text"] as? String) == ClaudeTextScreenHandoffPolicy.notHandedOverResult)
}
