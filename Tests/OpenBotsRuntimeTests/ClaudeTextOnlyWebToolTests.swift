import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsRuntime

// The containment fence and the one door through it. Every test here either
// proves an ungranted turn is unchanged, or proves a granted turn gets exactly
// what its user granted it and nothing else.

@Test("A turn with no grant carries no tool anywhere in its request")
func claudeTextNoGrantIsTheDefault() throws {
    let request = try textOnlyTestRequest()
    #expect(request.allowedTools.isEmpty)
    #expect(!request.grantsTools)
    #expect(request.allowedToolNames.isEmpty)
}

@Test("Granted tool names are the official CLI names in a fixed order")
func claudeTextToolNamesAreOfficialAndOrdered() throws {
    #expect(ClaudeTextOnlyTool.webSearch.toolName == "WebSearch")
    #expect(ClaudeTextOnlyTool.webFetch.toolName == "WebFetch")
    #expect(ClaudeTextOnlyTool.allCases.map(\.toolName) == ["WebSearch", "WebFetch"])
    // Set iteration order must never reach the command line.
    #expect(ClaudeTextOnlyTool.toolNames([.webFetch, .webSearch]) == ["WebSearch", "WebFetch"])
    #expect(ClaudeTextOnlyTool.toolNames([.webFetch]) == ["WebFetch"])
    #expect(ClaudeTextOnlyTool.toolNames([]).isEmpty)
    let request = try textOnlyTestRequest(allowedTools: [.webFetch, .webSearch])
    #expect(request.allowedToolNames == ["WebSearch", "WebFetch"])
}

/// Every other tool family the CLI can expose, written out rather than read
/// from the builder, so a name dropped from the deny list cannot pass unseen.
private let grantedDeniedTools = "Agent,AskUserQuestion,Artifact,Bash,BashOutput,Brief,ClaudeDesign,CronCreate,CronDelete,"
    + "CronList,DesignSync,Edit,EndConversation,EnterWorktree,ExitWorktree,Glob,Grep,JavaScript,KillShell,LS,LSP,"
    + "ListAgents,ListConnectors,ListMcpResourcesTool,ListPlugins,ListSkills,Monitor,MultiEdit,NotebookEdit,PowerShell,"
    + "Projects,PushNotification,REPL,Read,ReadMcpResourceDirTool,ReadMcpResourceTool,RefreshMcpTools,RemoteTrigger,"
    + "ScheduleWakeup,SearchMcpRegistry,SearchPlugins,SearchSkills,SendFeedback,SendFile,SendMessage,SendUserFile,"
    + "SendUserMessage,Skill,Snip,Task,TaskCreate,TaskGet,TaskList,TaskOutput,TaskStop,TaskUpdate,Tmux,TodoWrite,"
    + "ToolSearch,WebBrowser,Workflow,Write,mcp__*"

@Test("A granted text command names exactly its tools and keeps every containment flag")
func claudeTextGrantedCommandContract() throws {
    let request = try textOnlyTestRequest(allowedTools: [.webSearch, .webFetch])
    let arguments = ClaudeTextOnlyCommandBuilder.arguments(for: request)
    // Every expected value is a literal. Nothing here is computed by the
    // builder under test, so a drift in the settings JSON, the deny list or
    // the turn cap is a failure, not a redefinition of what is expected.
    let deniedJSON: String = grantedDeniedTools.split(separator: ",").map { "\"\($0)\"" }.joined(separator: ",")
    let settings: String = "{\"disableAllHooks\":true,\"disableClaudeAiConnectors\":true,\"enableArtifact\":false,\"enabledPlugins\":{\"agents-md@builtin\":false},"
        + "\"syncClaudeAiSkills\":false,\"switchModelsOnFlag\":false,"
        + "\"permissions\":{\"defaultMode\":\"dontAsk\",\"allow\":[\"WebSearch\",\"WebFetch\"],\"deny\":[" + deniedJSON + "]}}"
    let promptFile: String = request.target.temporaryDirectoryURL
        .appendingPathComponent("openbots-system-prompt-\(request.runID.uuidString.lowercased()).txt").path
    let expected: [String] = [
        "--print", "--input-format", "stream-json", "--output-format", "stream-json",
        "--include-partial-messages", "--replay-user-messages", "--verbose", "--safe-mode", "--restricted",
        "--no-session-persistence", "--no-chrome", "--disable-slash-commands", "--strict-mcp-config",
        "--mcp-config", "{\"mcpServers\":{}}", "--settings", settings,
        "--setting-sources", "", "--permission-mode", "dontAsk",
        "--tools", "WebSearch,WebFetch",
        "--disallowedTools", grantedDeniedTools,
        "--allowedTools", "WebSearch,WebFetch",
        "--model", "sonnet", "--max-turns", "16", "--session-id", request.sessionID.uuidString.lowercased(),
        "--system-prompt-file", promptFile
    ]
    #expect(arguments == expected)
    // Nothing a grant touches may reopen a fence the no-grant turn holds shut.
    for forbidden in ["--add-dir", "--resume", "--continue", "--permission-prompt-tool", "--allow-dangerously-skip-permissions",
                      "--fork-session", "--forward-subagent-text", "--include-hook-events", "--ide", "--worktree"] {
        #expect(!arguments.contains(forbidden))
    }
    #expect(!arguments.contains(request.text))
    #expect(!arguments.contains(request.systemPrompt))
}

@Test("One granted tool grants only that tool, and the other stays denied")
func claudeTextSingleGrantIsNarrow() throws {
    for (tool, name, other) in [(ClaudeTextOnlyTool.webSearch, "WebSearch", "WebFetch"),
                                (ClaudeTextOnlyTool.webFetch, "WebFetch", "WebSearch")] {
        let request = try textOnlyTestRequest(allowedTools: [tool])
        let arguments = ClaudeTextOnlyCommandBuilder.arguments(for: request)
        let tools = try #require(arguments.firstIndex(of: "--tools").map { arguments[$0 + 1] })
        #expect(tools == name)
        let allowed = try #require(arguments.firstIndex(of: "--allowedTools").map { arguments[$0 + 1] })
        #expect(allowed == name)
        let denied = try #require(arguments.firstIndex(of: "--disallowedTools").map { arguments[$0 + 1] })
            .split(separator: ",").map(String.init)
        #expect(denied.contains(other))
        #expect(!denied.contains(name))
        let permissions = try grantedPermissions(request)
        #expect(permissions.allow == [name])
        #expect(permissions.deny.contains(other))
        #expect(!permissions.deny.contains(name))
    }
}

@Test("Granted permissions allow only the granted tools and deny everything else by name")
func claudeTextGrantedPermissionsAreNarrow() throws {
    let request = try textOnlyTestRequest(allowedTools: [.webSearch, .webFetch])
    let settings = try #require(JSONSerialization.jsonObject(
        with: Data(ClaudeTextOnlyCommandBuilder.settingsJSON(for: request).utf8)) as? [String: Any])
    #expect(settings["disableAllHooks"] as? Bool == true)
    #expect(settings["disableClaudeAiConnectors"] as? Bool == true)
    #expect(settings["enableArtifact"] as? Bool == false)
    #expect(settings["syncClaudeAiSkills"] as? Bool == false)
    #expect(settings["switchModelsOnFlag"] as? Bool == false)
    let permissions = try grantedPermissions(request)
    // Deny-by-default is the mode itself: dontAsk denies anything not
    // pre-approved. A blanket "*" deny would shadow the grant, so it is gone
    // and every other tool family is denied by name instead.
    #expect(permissions.defaultMode == "dontAsk")
    #expect(permissions.allow == ["WebSearch", "WebFetch"])
    #expect(!permissions.deny.contains("*"))
    for denied in ["Bash", "Read", "Write", "Edit", "Glob", "Grep", "NotebookEdit", "REPL", "JavaScript",
                   "Agent", "Task", "Skill", "Workflow", "WebBrowser", "SendMessage", "EndConversation", "mcp__*"] {
        #expect(permissions.deny.contains(denied))
    }
    #expect(!permissions.deny.contains("WebSearch"))
    #expect(!permissions.deny.contains("WebFetch"))
}

@Test("A granted run accepts its own tool round trip, keeps what it said before the call, and the result only closes it")
func claudeTextStreamAcceptsGrantedToolRoundTrip() throws {
    let request = try textOnlyTestRequest(allowedTools: [.webSearch])
    var stream = ClaudeTextOnlyStream(request: request)
    var events: [ClaudeTextOnlyEvent] = []
    // The CLI's result text is the last assistant message alone. The reply is
    // everything the model said, so the narration before the call is kept, and
    // the answer after the call opens a new paragraph.
    var data = try textOnlyTestInit(request, override: ["tools": ["WebSearch"]])
    data += try textOnlyTestReplay(request)
    data += try webToolMessageStart(request)
    data += try textOnlyTestDelta(request, text: "Looking it up.")
    data += try webToolBlockStart(request, name: "WebSearch", id: "toolu_01")
    data += try webToolInputDelta(request, partial: "{\"query\":\"swift 6\"}")
    data += try webToolStop(request)
    data += try webToolAssistant(request, name: "WebSearch", id: "toolu_01")
    data += try webToolResult(request, ids: ["toolu_01"])
    data += try webToolMessageStart(request)
    data += try textOnlyTestDelta(request, text: "Swift 6 is current.")
    data += try textOnlyTestResult(request, override: ["result": "Swift 6 is current."])
    for byte in data { events += try stream.consume(Data([byte])) }
    #expect(events.contains(.inputAcknowledged(messageID: request.messageID)))
    #expect(events.contains(.textSnapshot("Looking it up.")))
    #expect(events.contains(.textSnapshot("Looking it up.\n\nSwift 6 is current.")))
    // Every snapshot extends the one before it, which is what persistence
    // requires of a reply it is asked to save in pieces.
    let snapshots = events.compactMap { if case .textSnapshot(let text) = $0 { text } else { nil } }
    for (earlier, later) in zip(snapshots, snapshots.dropFirst()) { #expect(later.hasPrefix(earlier)) }
    #expect(stream.grantedToolUseCount == 1)
    #expect(stream.grantedToolResultCount == 1)
    #expect(stream.finish(exitCode: 0) == .success(.init(sessionID: request.sessionID,
        actualModel: "claude-sonnet-5", text: "Looking it up.\n\nSwift 6 is current.",
        confirmedActualModel: "claude-sonnet-5")))
}

@Test("A web fetch whose page answered with an error status is a failed call, though the CLI does not flag it")
func claudeTextStreamWebFetchErrorStatusFails() throws {
    // Claude Code 2.1.280, seen live: a shopping site answered 500, the tool_result carried no is_error, and only the frame's
    // tool_use_result said code 500. The activity line read "Read <url>".
    func finished(_ name: String, code: Any?) throws -> [ClaudeTextOnlyEvent] {
        let request = try textOnlyTestRequest(allowedTools: [.webSearch, .webFetch])
        var stream = ClaudeTextOnlyStream(request: request)
        var data = try textOnlyTestInit(request, override: ["tools": ["WebSearch", "WebFetch"]])
        data += try textOnlyTestReplay(request)
        data += try webToolAssistant(request, name: name, id: "toolu_01")
        var frame: [String: Any] = ["type": "user", "uuid": UUID().uuidString, "session_id": request.sessionID.uuidString,
            "parent_tool_use_id": NSNull(),
            "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_01",
                "content": "The server returned HTTP 500 Internal Server Error."]]]]
        if let code { frame["tool_use_result"] = ["bytes": 0, "code": code, "codeText": "Internal Server Error"] }
        data += try textOnlyTestLine(frame)
        var events: [ClaudeTextOnlyEvent] = []
        for byte in data { events += try stream.consume(Data([byte])) }
        return events.filter { if case .toolFinished = $0 { true } else { false } }
    }
    #expect(try finished("WebFetch", code: 500) == [.toolFinished(toolUseID: "toolu_01", failed: true)])
    #expect(try finished("WebFetch", code: 404) == [.toolFinished(toolUseID: "toolu_01", failed: true)])
    #expect(try finished("WebFetch", code: 200) == [.toolFinished(toolUseID: "toolu_01", failed: false)])
    #expect(try finished("WebFetch", code: nil) == [.toolFinished(toolUseID: "toolu_01", failed: false)])
    // Only a number is a status; a flag or text in its place says nothing.
    #expect(try finished("WebFetch", code: true) == [.toolFinished(toolUseID: "toolu_01", failed: false)])
    #expect(try finished("WebFetch", code: "500") == [.toolFinished(toolUseID: "toolu_01", failed: false)])
    // Another tool's result is not read for a status.
    #expect(try finished("WebSearch", code: 500) == [.toolFinished(toolUseID: "toolu_01", failed: false)])
}

@Test("A web page's error status is the failed fetch's reason")
func webFetchErrorStatusIsItsReason() throws {
    let request = try textOnlyTestRequest(allowedTools: [.webSearch, .webFetch])
    var stream = ClaudeTextOnlyStream(request: request)
    var data = try textOnlyTestInit(request, override: ["tools": ["WebSearch", "WebFetch"]])
    data += try textOnlyTestReplay(request)
    data += try webToolAssistant(request, name: "WebFetch", id: "toolu_01")
    data += try textOnlyTestLine(["type": "user", "uuid": UUID().uuidString, "session_id": request.sessionID.uuidString,
        "parent_tool_use_id": NSNull(), "tool_use_result": ["bytes": 0, "code": 503, "codeText": "Service Unavailable"],
        "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_01", "content": "Read it."]]]])
    var events: [ClaudeTextOnlyEvent] = []
    for byte in data { events += try stream.consume(Data([byte])) }
    #expect(events.suffix(2) == [.toolFailureReason(toolUseID: "toolu_01", reason: "The page answered with status 503."),
                                 .toolFinished(toolUseID: "toolu_01", failed: true)])
}

@Test("A granted result must be how the streamed reply ends, and silent tool rounds open no empty paragraphs")
func claudeTextStreamGrantedResultClosesTheStreamedText() throws {
    let request = try textOnlyTestRequest(allowedTools: [.webSearch])
    var spoken = try textOnlyTestInit(request, override: ["tools": ["WebSearch"]])
    spoken += try textOnlyTestReplay(request)
    spoken += try webToolMessageStart(request)
    spoken += try textOnlyTestDelta(request, text: "Checking.\n")
    spoken += try webToolBlockStart(request, name: "WebSearch", id: "toolu_01")
    spoken += try webToolStop(request)
    spoken += try webToolAssistant(request, name: "WebSearch", id: "toolu_01")
    spoken += try webToolResult(request, ids: ["toolu_01"])
    // A result that is not the end of what streamed is some other message.
    var mismatched = ClaudeTextOnlyStream(request: request)
    _ = try mismatched.consume(spoken + webToolMessageStart(request) + textOnlyTestDelta(request, text: "Found it."))
    #expect(throws: ClaudeTextOnlyFailure.invalidStream) {
        try mismatched.consume(textOnlyTestResult(request, override: ["result": "Something else entirely."]))
    }
    // Trailing whitespace the CLI trims from its result does not break the match,
    // and a paragraph already ended is not ended twice.
    var trimmed = ClaudeTextOnlyStream(request: request)
    _ = try trimmed.consume(spoken + webToolMessageStart(request) + textOnlyTestDelta(request, text: "Found it.\n"))
    #expect(try trimmed.consume(textOnlyTestResult(request, override: ["result": "Found it."]))
        == [.textSnapshot("Checking.\n\nFound it.\n")])
    // Two silent tool rounds between two spoken messages open one paragraph, not three.
    var silent = ClaudeTextOnlyStream(request: request)
    var silentRound = try webToolMessageStart(request)
    silentRound += try webToolBlockStart(request, name: "WebSearch", id: "toolu_02")
    silentRound += try webToolStop(request)
    silentRound += try webToolAssistant(request, name: "WebSearch", id: "toolu_02")
    silentRound += try webToolResult(request, ids: ["toolu_02"])
    silentRound += try webToolMessageStart(request)
    _ = try silent.consume(spoken + silentRound)
    #expect(try silent.consume(textOnlyTestDelta(request, text: "Done.")) == [.textSnapshot("Checking.\n\nDone.")])
    // A granted run that never calls a tool is closed by a result equal to its text.
    var plain = ClaudeTextOnlyStream(request: request)
    _ = try plain.consume(textOnlyTestInit(request, override: ["tools": ["WebSearch"]]) + textOnlyTestReplay(request)
        + webToolMessageStart(request) + textOnlyTestDelta(request, text: "Hello back"))
    #expect(try plain.consume(textOnlyTestResult(request)) == [.textSnapshot("Hello back")])
    #expect(plain.finish(exitCode: 0) == .success(.init(sessionID: request.sessionID,
        actualModel: "claude-sonnet-5", text: "Hello back", confirmedActualModel: "claude-sonnet-5")))
}

@Test("A granted run drops the heartbeats of its own tool calls, and nothing else's")
func claudeTextStreamAdmitsBoundedToolHeartbeats() throws {
    let request = try textOnlyTestRequest(allowedTools: [.webFetch])
    let opened = try textOnlyTestInit(request, override: ["tools": ["WebFetch"]]) + textOnlyTestReplay(request)
        + webToolBlockStart(request, name: "WebFetch", id: "toolu_01")
    var stream = ClaudeTextOnlyStream(request: request)
    _ = try stream.consume(opened)
    // The CLI's executor heartbeats every thirty seconds, naming the call by
    // its own identifier plus a heartbeat suffix.
    for tick in 0..<3 {
        #expect(try stream.consume(webToolHeartbeat(request, id: "toolu_01-heartbeat-\(tick)", name: "WebFetch",
            elapsed: 30 * (tick + 1))).isEmpty)
    }
    #expect(stream.toolProgressFrameCount == 3)
    // The reply is untouched by them.
    #expect(try stream.consume(textOnlyTestDelta(request, text: "Read it.")) == [.textSnapshot("Read it.")])
    // A call this run never announced, a tool it was not granted, an extra
    // field, a foreign session and a flag that is not set are all refused.
    let refused: [(String, Data)] = [
        ("unannounced call", try webToolHeartbeat(request, id: "toolu_ghost-heartbeat-0", name: "WebFetch", elapsed: 30)),
        ("ungranted tool", try webToolHeartbeat(request, id: "toolu_01-heartbeat-9", name: "Bash", elapsed: 30)),
        ("extra field", try webToolHeartbeat(request, id: "toolu_01-heartbeat-9", name: "WebFetch", elapsed: 30,
            extra: ["task_id": "t1"])),
        ("foreign session", try webToolHeartbeat(request, id: "toolu_01-heartbeat-9", name: "WebFetch", elapsed: 30,
            extra: ["session_id": UUID().uuidString])),
        ("flag not set", try webToolHeartbeat(request, id: "toolu_01-heartbeat-9", name: "WebFetch", elapsed: 30,
            extra: ["heartbeat": false]))
    ]
    for (label, frame) in refused {
        var fresh = ClaudeTextOnlyStream(request: request)
        _ = try fresh.consume(opened)
        #expect(throws: ClaudeTextOnlyFailure.invalidStream, "\(label) must be refused") { try fresh.consume(frame) }
    }
    // An ungranted run has no calls, so it has no heartbeats either.
    let ungranted = try textOnlyTestRequest()
    var strict = ClaudeTextOnlyStream(request: ungranted)
    _ = try strict.consume(textOnlyTestInit(ungranted) + textOnlyTestReplay(ungranted))
    #expect(throws: ClaudeTextOnlyFailure.invalidStream) {
        try strict.consume(webToolHeartbeat(ungranted, id: "toolu_01-heartbeat-0", name: "WebFetch", elapsed: 30))
    }
    // The budget is finite.
    var flooded = ClaudeTextOnlyStream(request: request)
    _ = try flooded.consume(opened)
    for tick in 0..<ClaudeTextOnlyStream.maximumToolProgressFrames {
        _ = try flooded.consume(webToolHeartbeat(request, id: "toolu_01-heartbeat-\(tick)", name: "WebFetch", elapsed: 30))
    }
    #expect(throws: ClaudeTextOnlyFailure.invalidStream) {
        try flooded.consume(webToolHeartbeat(request, id: "toolu_01-heartbeat-more", name: "WebFetch", elapsed: 30))
    }
}

@Test("The CLI's turn cap ends a granted run as its own failure, keeping what streamed")
func claudeTextStreamReportsTheTurnCapAsItsOwnFailure() throws {
    let request = try textOnlyTestRequest(allowedTools: [.webSearch])
    var stream = ClaudeTextOnlyStream(request: request)
    var emitted: [ClaudeTextOnlyEvent] = []
    var frames = try textOnlyTestInit(request, override: ["tools": ["WebSearch"]])
    frames += try textOnlyTestReplay(request)
    frames += try webToolMessageStart(request)
    frames += try textOnlyTestDelta(request, text: "Still reading.")
    frames += try webToolBlockStart(request, name: "WebSearch", id: "toolu_01")
    frames += try webToolStop(request)
    frames += try webToolAssistant(request, name: "WebSearch", id: "toolu_01")
    frames += try webToolResult(request, ids: ["toolu_01"])
    frames += try textOnlyTestLine(["type": "result", "subtype": "error_max_turns", "session_id": request.sessionID.uuidString,
        "is_error": true, "num_turns": 16, "errors": ["Reached maximum number of turns (16)"],
        "modelUsage": [request.expectedResolvedModel: [:]], "permission_denials": []])
    #expect(throws: ClaudeTextOnlyRejection(failure: .turnLimitReached, code: .turnLimitReached)) {
        try stream.consume(frames) { emitted.append($0) }
    }
    #expect(emitted.contains(.textSnapshot("Still reading.")))
    #expect(stream.finish(exitCode: 0) == .failed(.invalidStream))
}

/// Seen live: a member's research leg ended as an invalid
/// stream (`responseMismatch`) at its seventeenth tool call, because the budget
/// for distinct calls was sixteen and one round can carry several calls. A
/// five-language research captured from the CLI made seventeen
/// calls in fifty-nine seconds: five searches in one message, then fetches.
@Test("A research that makes more than sixteen calls in a few rounds completes")
func claudeTextStreamAdmitsAResearchOfSeventeenCalls() throws {
    let request = try textOnlyTestRequest(allowedTools: [.webSearch, .webFetch])
    var stream = ClaudeTextOnlyStream(request: request)
    var emitted: [ClaudeTextOnlyEvent] = []
    var frames = try textOnlyTestInit(request, override: ["tools": ["WebSearch", "WebFetch"]])
    frames += try textOnlyTestReplay(request)
    frames += try webToolMessageStart(request)
    frames += try textOnlyTestDelta(request, text: "Checking the primary sources.")
    // Five searches announced in one round, then twelve fetches over two more.
    var announced: [String] = []
    for (round, calls) in [("WebSearch", 5), ("WebFetch", 6), ("WebFetch", 6)].enumerated() {
        if round > 0 { frames += try webToolMessageStart(request) }
        var ids: [String] = []
        for call in 0..<calls.1 {
            let id = "toolu_0\(round)_\(call)"
            ids.append(id)
            frames += try webToolBlockStart(request, name: calls.0, id: id)
            frames += try webToolAssistant(request, name: calls.0, id: id)
        }
        frames += try webToolStop(request)
        // The CLI returns results one frame each; a frame carries at most eight.
        for id in ids { frames += try webToolResult(request, ids: [id]) }
        announced += ids
    }
    #expect(announced.count == 17)
    let answer = "Swift 6.3, Rust 1.94, Go 1.27, Kotlin 2.4 and Zig 0.16 are the current releases."
    frames += try webToolMessageStart(request)
    frames += try textOnlyTestDelta(request, text: answer)
    frames += try textOnlyTestResult(request, override: ["result": answer])
    try stream.consume(frames) { emitted.append($0) }
    #expect(stream.grantedToolUseCount == 17)
    #expect(stream.grantedToolResultCount == 17)
    #expect(emitted.last == .textSnapshot("Checking the primary sources.\n\n" + answer))
    #expect(stream.finish(exitCode: 0) == .success(.init(sessionID: request.sessionID,
        actualModel: "claude-sonnet-5", text: "Checking the primary sources.\n\n" + answer,
        confirmedActualModel: "claude-sonnet-5")))
}

@Test("A call past the app's own budget ends the run as its limit, keeping what streamed")
func claudeTextStreamReportsTheCallBudgetAsItsOwnFailure() throws {
    let request = try textOnlyTestRequest(allowedTools: [.webFetch])
    var stream = ClaudeTextOnlyStream(request: request)
    var emitted: [ClaudeTextOnlyEvent] = []
    var frames = try textOnlyTestInit(request, override: ["tools": ["WebFetch"]])
    frames += try textOnlyTestReplay(request)
    frames += try webToolMessageStart(request)
    frames += try textOnlyTestDelta(request, text: "Still reading.")
    for call in 0..<ClaudeTextOnlyStream.maximumGrantedToolUses {
        frames += try webToolBlockStart(request, name: "WebFetch", id: "toolu_budget_\(call)")
    }
    try stream.consume(frames) { emitted.append($0) }
    #expect(stream.grantedToolUseCount == ClaudeTextOnlyStream.maximumGrantedToolUses)
    // The same call announced again is not a new one and costs nothing.
    try stream.consume(webToolAssistant(request, name: "WebFetch", id: "toolu_budget_0"))
    #expect(stream.grantedToolUseCount == ClaudeTextOnlyStream.maximumGrantedToolUses)
    // The rejection itself, with the diagnostic code the process records, not
    // the bare failure the one-argument test helper unwraps it to.
    #expect(throws: ClaudeTextOnlyRejection(failure: .turnLimitReached, code: .turnLimitReached)) {
        try stream.consume(webToolBlockStart(request, name: "WebFetch", id: "toolu_budget_one_more")) { emitted.append($0) }
    }
    #expect(emitted.contains(.textSnapshot("Still reading.")))
    #expect(stream.finish(exitCode: 0) == .failed(.invalidStream))
}

@Test("An ungranted run still rejects every frame of a tool round trip")
func claudeTextStreamRejectsToolRoundTripWithoutGrant() throws {
    let request = try textOnlyTestRequest()
    let frames: [(String, Data)] = [
        ("block start", try webToolBlockStart(request, name: "WebSearch", id: "toolu_01")),
        ("input delta", try webToolInputDelta(request, partial: "{}")),
        ("assistant tool_use", try webToolAssistant(request, name: "WebSearch", id: "toolu_01")),
        ("stop reason", try webToolStop(request))
    ]
    for (label, frame) in frames {
        var stream = ClaudeTextOnlyStream(request: request)
        _ = try stream.consume(textOnlyTestInit(request) + textOnlyTestReplay(request))
        #expect(throws: ClaudeTextOnlyFailure.invalidStream, "\(label) must stay rejected") {
            try stream.consume(frame)
        }
    }
    // The tool result arrives as a second user frame; with no grant it is still
    // a duplicate replay, and a nested frame is still a nested tool event.
    var afterReplay = ClaudeTextOnlyStream(request: request)
    _ = try afterReplay.consume(textOnlyTestInit(request) + textOnlyTestReplay(request))
    #expect(throws: ClaudeTextOnlyFailure.invalidStream) { try afterReplay.consume(webToolResult(request, ids: ["toolu_01"])) }
    var nested = ClaudeTextOnlyStream(request: request)
    _ = try nested.consume(textOnlyTestInit(request) + textOnlyTestReplay(request))
    #expect(throws: ClaudeTextOnlyFailure.invalidStream) {
        try nested.consume(textOnlyTestDelta(request, text: "x", parent: "toolu_01"))
    }
}

@Test("A granted run rejects a tool it was not granted")
func claudeTextStreamRejectsUngrantedTool() throws {
    let request = try textOnlyTestRequest(allowedTools: [.webSearch])
    for frame in [try webToolBlockStart(request, name: "WebFetch", id: "toolu_02"),
                  try webToolBlockStart(request, name: "Bash", id: "toolu_03"),
                  try webToolAssistant(request, name: "WebFetch", id: "toolu_02")] {
        var stream = ClaudeTextOnlyStream(request: request)
        _ = try stream.consume(textOnlyTestInit(request, override: ["tools": ["WebSearch"]]) + textOnlyTestReplay(request))
        #expect(throws: ClaudeTextOnlyFailure.invalidStream) { try stream.consume(frame) }
    }
}

@Test("A granted run admits only results and nested frames of calls it made itself")
func claudeTextStreamCorrelatesToolIdentifiers() throws {
    let request = try textOnlyTestRequest(allowedTools: [.webSearch])
    // A result for a call that was never announced is not this run's business.
    var unannounced = ClaudeTextOnlyStream(request: request)
    _ = try unannounced.consume(textOnlyTestInit(request, override: ["tools": ["WebSearch"]]) + textOnlyTestReplay(request))
    #expect(throws: ClaudeTextOnlyFailure.invalidStream) { try unannounced.consume(webToolResult(request, ids: ["toolu_ghost"])) }
    // Neither is a frame produced underneath somebody else's call.
    var foreignParent = ClaudeTextOnlyStream(request: request)
    _ = try foreignParent.consume(textOnlyTestInit(request, override: ["tools": ["WebSearch"]])
        + textOnlyTestReplay(request) + webToolBlockStart(request, name: "WebSearch", id: "toolu_01"))
    #expect(throws: ClaudeTextOnlyFailure.invalidStream) {
        try foreignParent.consume(textOnlyTestDelta(request, text: "leak", parent: "toolu_subagent"))
    }
    // A frame underneath this run's own granted call is admitted, because this
    // run granted that call — and its text is dropped rather than spoken. A
    // tool's working is not the bot's words, and a future granted tool that
    // narrates inside its own call must not stream that as the reply.
    var own = ClaudeTextOnlyStream(request: request)
    _ = try own.consume(textOnlyTestInit(request, override: ["tools": ["WebSearch"]])
        + textOnlyTestReplay(request) + webToolBlockStart(request, name: "WebSearch", id: "toolu_01"))
    #expect(try own.consume(textOnlyTestDelta(request, text: "inside", parent: "toolu_01")).isEmpty)
    // What the assistant says in its own frame still becomes the reply.
    #expect(try own.consume(textOnlyTestDelta(request, text: "answer")) == [.textSnapshot("answer")])
}

@Test("Initialization must report exactly the granted tools")
func claudeTextStreamPinsInitializationTools() throws {
    let granted = try textOnlyTestRequest(allowedTools: [.webSearch, .webFetch])
    for override in [["tools": []], ["tools": ["WebSearch"]], ["tools": ["WebSearch", "WebFetch", "Bash"]],
                     ["tools": ["WebSearch", "WebSearch"]], ["tools": ["WebSearch", "Read"]]] {
        var stream = ClaudeTextOnlyStream(request: granted)
        #expect(throws: ClaudeTextOnlyFailure.unsafeInitialization) { try stream.consume(textOnlyTestInit(granted, override: override)) }
    }
    var accepted = ClaudeTextOnlyStream(request: granted)
    let events = try accepted.consume(textOnlyTestInit(granted, override: ["tools": ["WebFetch", "WebSearch"]]))
    #expect(events == [.initialized(sessionID: granted.sessionID, actualModel: "claude-sonnet-5")])
    // A turn with no grant must still be told it has nothing at all.
    let ungranted = try textOnlyTestRequest()
    var strict = ClaudeTextOnlyStream(request: ungranted)
    #expect(throws: ClaudeTextOnlyFailure.unsafeInitialization) {
        try strict.consume(textOnlyTestInit(ungranted, override: ["tools": ["WebSearch"]]))
    }
}

@Test("A granted result may name the helper models its tools used, and must still name its own")
func claudeTextStreamAcceptsGrantedHelperUsage() throws {
    // A granted web tool runs its own internal model query, so a granted turn's
    // result names more than one model. The answering model must still be there.
    let request = try textOnlyTestRequest(allowedTools: [.webFetch])
    var stream = ClaudeTextOnlyStream(request: request)
    _ = try stream.consume(textOnlyTestInit(request, override: ["tools": ["WebFetch"]]) + textOnlyTestReplay(request)
        + textOnlyTestDelta(request, text: "Read it."))
    _ = try stream.consume(textOnlyTestResult(request, override: ["result": "Read it.",
        "modelUsage": [request.expectedResolvedModel: ["inputTokens": 10],
                       "claude-haiku-4-5-20251001": ["inputTokens": 3]]]))
    #expect(stream.finish(exitCode: 0) == .success(.init(sessionID: request.sessionID,
        actualModel: "claude-sonnet-5", text: "Read it.", confirmedActualModel: "claude-sonnet-5")))

    // Without its own model in the usage, nothing confirms who answered.
    for usage in [["claude-haiku-4-5-20251001": ["inputTokens": 3]] as [String: Any],
                  ["claude-opus-5": [:], "claude-haiku-4-5-20251001": [:]],
                  [request.expectedResolvedModel: "not-an-object"],
                  ["a": [:], "b": [:], "c": [:], "d": [:], "e": [:]]] {
        var rejecting = ClaudeTextOnlyStream(request: request)
        _ = try rejecting.consume(textOnlyTestInit(request, override: ["tools": ["WebFetch"]]) + textOnlyTestReplay(request))
        #expect(throws: ClaudeTextOnlyFailure.unsafeInitialization) {
            try rejecting.consume(textOnlyTestResult(request, override: ["modelUsage": usage]))
        }
    }

    // An ungranted turn still admits exactly one model and no more.
    let ungranted = try textOnlyTestRequest()
    var strict = ClaudeTextOnlyStream(request: ungranted)
    _ = try strict.consume(textOnlyTestInit(ungranted) + textOnlyTestReplay(ungranted))
    #expect(throws: ClaudeTextOnlyFailure.unsafeInitialization) {
        try strict.consume(textOnlyTestResult(ungranted, override: [
            "modelUsage": [ungranted.expectedResolvedModel: [:], "claude-haiku-4-5-20251001": [:]]]))
    }
}

// MARK: - Frames of a tool round trip

private func webToolMessageStart(_ request: ClaudeTextOnlyRequest) throws -> Data {
    try textOnlyTestLine(["type": "stream_event", "session_id": request.sessionID.uuidString,
        "event": ["type": "message_start",
                  "message": ["role": "assistant", "model": request.expectedResolvedModel, "content": []]]])
}

/// The heartbeat the CLI's tool executor emits every thirty seconds while a
/// call runs, as the 2.1.263 binary writes it.
private func webToolHeartbeat(_ request: ClaudeTextOnlyRequest, id: String, name: String, elapsed: Int,
                              extra: [String: Any] = [:]) throws -> Data {
    var value: [String: Any] = ["type": "tool_progress", "tool_use_id": id, "tool_name": name,
        "parent_tool_use_id": NSNull(), "elapsed_time_seconds": elapsed, "heartbeat": true,
        "session_id": request.sessionID.uuidString, "uuid": UUID().uuidString]
    value.merge(extra) { _, new in new }
    return try textOnlyTestLine(value)
}

private func webToolBlockStart(_ request: ClaudeTextOnlyRequest, name: String, id: String) throws -> Data {
    try textOnlyTestLine(["type": "stream_event", "session_id": request.sessionID.uuidString,
        "event": ["type": "content_block_start", "index": 1,
                  "content_block": ["type": "tool_use", "id": id, "name": name, "input": [:]]]])
}

private func webToolInputDelta(_ request: ClaudeTextOnlyRequest, partial: String) throws -> Data {
    try textOnlyTestLine(["type": "stream_event", "session_id": request.sessionID.uuidString,
        "event": ["type": "content_block_delta", "index": 1,
                  "delta": ["type": "input_json_delta", "partial_json": partial]]])
}

private func webToolStop(_ request: ClaudeTextOnlyRequest) throws -> Data {
    try textOnlyTestLine(["type": "stream_event", "session_id": request.sessionID.uuidString,
        "event": ["type": "message_delta", "delta": ["stop_reason": "tool_use"]]])
}

private func webToolAssistant(_ request: ClaudeTextOnlyRequest, name: String, id: String) throws -> Data {
    try textOnlyTestLine(["type": "assistant", "session_id": request.sessionID.uuidString,
        "message": ["role": "assistant", "model": request.expectedResolvedModel,
                    "content": [["type": "text", "text": "Looking it up. "],
                                ["type": "tool_use", "id": id, "name": name, "input": ["query": "swift 6"]]]]])
}

private func webToolResult(_ request: ClaudeTextOnlyRequest, ids: [String]) throws -> Data {
    try textOnlyTestLine(["type": "user", "uuid": UUID().uuidString, "session_id": request.sessionID.uuidString,
        "parent_tool_use_id": NSNull(),
        "message": ["role": "user",
                    "content": ids.map { ["type": "tool_result", "tool_use_id": $0, "content": "results"] }]])
}

private struct GrantedPermissions {
    let defaultMode: String
    let allow: [String]
    let deny: [String]
}

private func grantedPermissions(_ request: ClaudeTextOnlyRequest) throws -> GrantedPermissions {
    let settings = try #require(JSONSerialization.jsonObject(
        with: Data(ClaudeTextOnlyCommandBuilder.settingsJSON(for: request).utf8)) as? [String: Any])
    let permissions = try #require(settings["permissions"] as? [String: Any])
    return GrantedPermissions(defaultMode: try #require(permissions["defaultMode"] as? String),
        allow: try #require(permissions["allow"] as? [String]),
        deny: try #require(permissions["deny"] as? [String]))
}

// Production exposes only callback delivery, so the batching convenience the
// stream suite uses is repeated here rather than widening the runtime's API.
private extension ClaudeTextOnlyStream {
    mutating func consume(_ data: Data) throws -> [ClaudeTextOnlyEvent] {
        var events: [ClaudeTextOnlyEvent] = []
        do { try consume(data) { events.append($0) } }
        catch let rejection as ClaudeTextOnlyRejection { throw rejection.failure }
        return events
    }
}
