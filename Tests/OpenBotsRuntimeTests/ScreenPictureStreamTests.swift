import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsRuntime

// The screen preview: what Control this Mac last saw, handed up from the
// stream. Recorded on Claude Code 2.1.280 with
// Peekaboo 4.0.0 run the way the app runs it: `see` finishes with one user
// frame whose tool result holds its text and a PNG, and `tool_use_result`
// holds the same two again beside a `_meta`; `image` finishes with text only,
// "Captured 1 image(s)", and no picture at all. The pixels here are a stand-in:
// the recording was of the user's screen and stays out of the repository.

private let macServer = "openbots_" + String(repeating: "5ee1", count: 16)
private let browserServer = "openbots_" + String(repeating: "b0b0", count: 16)
/// A 1×1 PNG, standing in for the recorded screenshot.
private let stubPNG = Data(base64Encoded:
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==")!

private func screenRequest(servers: [(String, ClaudeTextConnectorRole)]) throws -> ClaudeTextOnlyRequest {
    let access = try ClaudeTextConnectorAccess(servers: servers.map { name, role in
        try ClaudeTextConnectorServer(name: name, role: role,
            program: .installedTool(URL(fileURLWithPath: "/private/tmp/openbots-screen-fixture")), options: [],
            environment: [:])
    })
    return try textOnlyTestRequest(connectorAccess: access)
}

/// One call in the 2.1.280 order, finished the way the recording finished it.
private func callFrames(_ request: ClaudeTextOnlyRequest, server: String, tool: String, index: Int,
                        result: [[String: Any]]) throws -> [Data] {
    let id = "toolu_screen_\(index)", name = "mcp__\(server)__\(tool)"
    let session = request.sessionID.uuidString
    return [
        try textOnlyTestLine(["type": "assistant", "session_id": session,
            "message": ["role": "assistant", "model": request.expectedResolvedModel,
                        "content": [["type": "tool_use", "id": id, "name": name, "input": ["app_target": "TextEdit"]]]]]),
        try textOnlyTestLine(["type": "control_request", "request_id": "req-\(index)", "session_id": session,
            "request": ["subtype": "can_use_tool", "tool_name": name, "tool_use_id": id,
                        "input": ["app_target": "TextEdit"]]]),
        try textOnlyTestLine(["type": "control_response",
            "response": ["subtype": "success", "request_id": "req-\(index)", "response": ["behavior": "allow"]]]),
        try textOnlyTestLine(["type": "user", "uuid": UUID().uuidString, "session_id": session,
            "parent_tool_use_id": NSNull(), "timestamp": "2026-09-22T19:44:00.000Z",
            "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": result]]],
            "tool_use_result": ["content": result, "_meta": ["coordinate_context": ["version": 1]]]]),
    ]
}

private func seeResult(_ data: Data = stubPNG, mediaType: String = "image/png") -> [[String: Any]] {
    [["type": "text", "text": "📸 UI State Captured\nApplication: TextEdit"],
     ["type": "image", "source": ["type": "base64", "media_type": mediaType, "data": data.base64EncodedString()]]]
}

private func run(_ request: ClaudeTextOnlyRequest, calls: [(server: String, tool: String, result: [[String: Any]])])
    throws -> [ClaudeTextOnlyEvent] {
    var stream = ClaudeTextOnlyStream(request: request, control: ClaudeTextTurnControl())
    stream.expectControlInitialization(requestID: "init-1")
    var events: [ClaudeTextOnlyEvent] = []
    try stream.consume(try textOnlyTestLine(["type": "control_response",
        "response": ["subtype": "success", "request_id": "init-1", "response": [String: Any]()]])) { _ in }
    let tools = Array(Set(calls.map { "mcp__\($0.server)__\($0.tool)" })).sorted()
    let servers = Set(calls.map(\.server)).sorted().map { ["name": $0, "status": "connected"] }
    try stream.consume(try textOnlyTestInit(request, override: [
        "tools": request.grantedToolNames + request.appServerToolNames + tools,
        "mcp_servers": servers + appServerEntries(request), "permissionMode": "default"])) { _ in }
    try stream.consume(try textOnlyTestReplay(request)) { _ in }
    for (index, call) in calls.enumerated() {
        for frame in try callFrames(request, server: call.server, tool: call.tool, index: index, result: call.result) {
            try stream.consume(frame) { events.append($0) }
        }
    }
    return events
}

private func pictures(_ events: [ClaudeTextOnlyEvent]) -> [ClaudeTextScreenPicture] {
    events.compactMap { if case .screenPicture(let picture) = $0 { picture } else { nil } }
}

@Test("A Control this Mac look hands up the picture it saw, decoded once though the CLI writes it twice, before the call finishes")
func aMacControlLookHandsUpItsPicture() throws {
    let events = try run(try screenRequest(servers: [(macServer, .macControl)]),
                         calls: [(macServer, "see", seeResult())])
    #expect(pictures(events) == [ClaudeTextScreenPicture(toolUseID: "toolu_screen_0", mediaType: "image/png", data: stubPNG)])
    let pictureIndex = events.firstIndex { if case .screenPicture = $0 { true } else { false } }
    let finishedIndex = events.firstIndex { if case .toolFinished = $0 { true } else { false } }
    #expect(pictureIndex != nil && finishedIndex != nil && pictureIndex! < finishedIndex!)
}

@Test("The image tool's text-only result, as 2.1.280 writes it, hands up nothing and the call still finishes")
func theImageToolsTextOnlyResultHandsUpNothing() throws {
    let events = try run(try screenRequest(servers: [(macServer, .macControl)]),
                         calls: [(macServer, "image", [["type": "text", "text": "Captured 1 image(s)"]])])
    #expect(pictures(events).isEmpty)
    #expect(events.contains(.toolFinished(toolUseID: "toolu_screen_0", failed: false)))
}

@Test("Only Control this Mac shows the user's screen: a browser screenshot is not handed up")
func onlyControlThisMacHandsUpAPicture() throws {
    let events = try run(try screenRequest(servers: [(macServer, .macControl), (browserServer, .browser)]),
                         calls: [(browserServer, "take_screenshot", seeResult()), (macServer, "see", seeResult())])
    #expect(pictures(events).map(\.toolUseID) == ["toolu_screen_1"])
}

@Test("A picture that is not a PNG or JPEG, or not base64, is not handed up, and the reply goes on")
func anUnreadablePictureIsLeftOut() throws {
    let events = try run(try screenRequest(servers: [(macServer, .macControl)]), calls: [
        (macServer, "see", seeResult(mediaType: "image/svg+xml")),
        (macServer, "see", [["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "%%%not"]]]),
        (macServer, "see", seeResult(mediaType: "image/jpeg")),
    ])
    #expect(pictures(events).map(\.toolUseID) == ["toolu_screen_2"])
    #expect(events.filter { if case .toolFinished = $0 { true } else { false } }.count == 3)
}
