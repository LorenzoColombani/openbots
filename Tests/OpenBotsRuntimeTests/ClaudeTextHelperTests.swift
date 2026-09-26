import Foundation
import Testing
@testable import OpenBotsRuntime

struct ClaudeTextHelperTests {
    private func request(web: Set<ClaudeTextOnlyTool> = []) throws -> ClaudeTextOnlyRequest {
        try textOnlyTestRequest(allowedTools: web, workAccess: ClaudeTextWorkAccess(
            workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/helper-desk.noindex"),
            protectedPaths: ["/Users/example/.ssh"]))
    }

    private var input: [String: Any] {
        ["subagent_type": "openbots-helper", "prompt": "Read the report and return three findings.",
         "description": "Read the report"]
    }

    private func ready(_ request: ClaudeTextOnlyRequest, control: ClaudeTextTurnControl) throws -> ClaudeTextOnlyStream {
        var stream = ClaudeTextOnlyStream(request: request, control: control)
        try stream.consume(textOnlyTestInit(request, override: ["tools": request.grantedToolNames, "permissionMode": "default"])) { _ in }
        try stream.consume(textOnlyTestReplay(request)) { _ in }
        return stream
    }

    private func announcement(_ request: ClaudeTextOnlyRequest, id: String = "helper-1", name: String = "Agent",
                              input: [String: Any]? = nil, parent: String? = nil) throws -> Data {
        var frame: [String: Any] = ["type": "assistant", "session_id": request.sessionID.uuidString,
            "message": ["role": "assistant", "model": request.expectedResolvedModel,
                        "content": [["type": "tool_use", "id": id, "name": name, "input": input ?? self.input]]]]
        if let parent { frame["parent_tool_use_id"] = parent }
        return try textOnlyTestLine(frame)
    }

    private func permission(_ request: ClaudeTextOnlyRequest, id: String = "helper-1", input: [String: Any]? = nil,
                            agentID: String? = nil, name: String = "Agent") throws -> Data {
        var body: [String: Any] = ["subtype": "can_use_tool", "tool_name": name, "tool_use_id": id,
                                  "input": input ?? self.input]
        if let agentID { body["agent_id"] = agentID }
        return try textOnlyTestLine(["type": "control_request", "request_id": "ask-" + id,
                                    "session_id": request.sessionID.uuidString, "request": body])
    }

    @Test("Both documented helper names keep the same approval, budget and parent isolation", arguments: ["Agent", "Task"])
    func helperWireAliases(name: String) throws {
        let request = try request(), control = ClaudeTextTurnControl()
        var stream = ClaudeTextOnlyStream(request: request, control: control)
        let names = request.grantedToolNames.map { $0 == "Agent" ? name : $0 }
        try stream.consume(textOnlyTestInit(request, override: ["tools": names, "permissionMode": "default"])) { _ in }
        try stream.consume(textOnlyTestReplay(request)) { _ in }
        for id in ["helper-1", "helper-2"] {
            try stream.consume(announcement(request, id: id, name: name)) { event in
                if case .toolUse(let use) = event { #expect(use.toolName == "Agent") }
            }
            try stream.consume(permission(request, id: id, name: name)) { event in
                guard case .permissionRequested(let question) = event else { Issue.record("Missing approval"); return }
                #expect(question.toolName == "Agent")
                control.register(question)
            }
            #expect(control.respond(requestID: "ask-" + id, allow: true))
        }
        try stream.consume(textOnlyTestDelta(request, text: "HIDDEN", parent: "helper-1")) { _ in }
        try stream.consume(textOnlyTestResult(request, override: ["parent_tool_use_id": "helper-1", "result": "HIDDEN"])) { _ in }
        #expect(stream.textSoFar.isEmpty && !stream.hasCompleted)
        #expect(throws: ClaudeTextOnlyRejection(failure: .turnLimitReached, code: .turnLimitReached)) {
            try stream.consume(permission(request, id: "helper-3", name: name)) { _ in }
        }
    }

    @Test("A helper alias neither grants unrequested work nor permits duplicate tool declarations")
    func helperAliasDoesNotWidenTools() throws {
        let web = try textOnlyTestRequest(allowedTools: [.webSearch])
        var ungranted = ClaudeTextOnlyStream(request: web)
        #expect(throws: ClaudeTextOnlyRejection.self) {
            try ungranted.consume(textOnlyTestInit(web, override: ["tools": ["WebSearch", "Task"]])) { _ in }
        }
        let request = try request()
        var duplicate = ClaudeTextOnlyStream(request: request)
        #expect(throws: ClaudeTextOnlyRejection.self) {
            try duplicate.consume(textOnlyTestInit(request,
                override: ["tools": request.grantedToolNames + ["Task"], "permissionMode": "default"])) { _ in }
        }
    }

    private func approve(_ request: ClaudeTextOnlyRequest, stream: inout ClaudeTextOnlyStream,
                         control: ClaudeTextTurnControl, id: String = "helper-1") throws {
        try stream.consume(announcement(request, id: id)) { _ in }
        try stream.consume(permission(request, id: id)) {
            if case .permissionRequested(let question) = $0 { control.register(question) }
        }
        #expect(control.respond(requestID: "ask-" + id, allow: true))
    }

    private func helperReplay(_ request: ClaudeTextOnlyRequest, blocks: Bool = false,
                              override: [String: Any] = [:]) throws -> Data {
        let prompt = input["prompt"] as! String
        var frame: [String: Any] = ["type": "user", "session_id": request.sessionID.uuidString,
            "uuid": UUID().uuidString, "parent_tool_use_id": "helper-1",
            "subagent_type": "openbots-helper", "task_description": input["description"]!,
            "message": ["role": "user", "content": blocks ? [["type": "text", "text": prompt]] as Any : prompt]]
        frame.merge(override) { _, replacement in replacement }
        return try textOnlyTestLine(frame)
    }

    @Test("An approved helper's exact initial prompt replay is private and accepted only once", arguments: [false, true])
    func helperPromptReplay(blocks: Bool) throws {
        let request = try request(), control = ClaudeTextTurnControl()
        var stream = try ready(request, control: control)
        try approve(request, stream: &stream, control: control)
        var events: [ClaudeTextOnlyEvent] = []
        try stream.consume(helperReplay(request, blocks: blocks)) { events.append($0) }
        #expect(events.isEmpty && stream.textSoFar.isEmpty && !stream.hasCompleted)
        #expect(stream.hasAcknowledgedInput && stream.grantedToolResultCount == 0)
        #expect(throws: ClaudeTextOnlyRejection.self) {
            try stream.consume(helperReplay(request, blocks: blocks)) { _ in }
        }
    }

    @Test("Helper replay cannot change its approved prompt, identity, parent or session")
    func helperReplayBinding() throws {
        let request = try request()
        let overrides: [[String: Any]] = [
            ["message": ["role": "user", "content": "Different assignment"]],
            ["message": ["role": "assistant", "content": input["prompt"]!]],
            ["subagent_type": "general-purpose"], ["task_description": "Different task"],
            ["parent_tool_use_id": "unknown"], ["parent_tool_use_id": NSNull()],
            ["session_id": UUID().uuidString], ["uuid": "invalid"]
        ]
        for override in overrides {
            let control = ClaudeTextTurnControl()
            var stream = try ready(request, control: control)
            try approve(request, stream: &stream, control: control)
            #expect(throws: ClaudeTextOnlyRejection.self) {
                try stream.consume(helperReplay(request, override: override)) { _ in }
            }
        }
    }

    @Test("Unapproved, denied and finished helpers cannot replay a prompt")
    func inactiveHelperReplay() throws {
        let request = try request()
        for state in 0..<3 {
            let control = ClaudeTextTurnControl()
            var stream = try ready(request, control: control)
            if state == 2 {
                try approve(request, stream: &stream, control: control)
                try stream.consume(textOnlyTestLine(["type": "user", "session_id": request.sessionID.uuidString,
                    "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "helper-1", "content": "Done"]]]])) { _ in }
            } else {
                try stream.consume(announcement(request)) { _ in }
                if state == 1 {
                    try stream.consume(permission(request)) { if case .permissionRequested(let question) = $0 { control.register(question) } }
                    #expect(control.respond(requestID: "ask-helper-1", allow: false))
                }
            }
            #expect(throws: ClaudeTextOnlyRejection.self) {
                try stream.consume(helperReplay(request)) { _ in }
            }
        }
    }

    @Test("Only work grants the app's foreground helper, with exact inherited tools, model and finite turns")
    func launchContract() throws {
        for web in [Set<ClaudeTextOnlyTool>(), [.webSearch], [.webFetch], [.webSearch, .webFetch]] {
            let request = try request(web: web)
            let arguments = ClaudeTextOnlyCommandBuilder.arguments(for: request)
            // Safe mode explicitly ignores --agents in the signed CLI, so it
            // cannot coexist with the granted app-owned helper. Independent
            // customization, connector and background fences still apply.
            #expect(!arguments.contains("--safe-mode"))
            for flag in ["--restricted", "--strict-mcp-config", "--no-chrome", "--disable-slash-commands"] {
                #expect(arguments.contains(flag))
            }
            let offset = try #require(arguments.firstIndex(of: "--agents"))
            let definitions = try #require(JSONSerialization.jsonObject(with: Data(arguments[offset + 1].utf8)) as? [String: Any])
            #expect(definitions.count == 1)
            let helper = try #require(definitions["openbots-helper"] as? [String: Any])
            #expect(helper["tools"] as? [String] == ["Bash", "Edit", "Glob", "Grep", "NotebookEdit", "Read", "Write", "AskUserQuestion"] + request.allowedToolNames)
            #expect(helper["model"] as? String == "inherit")
            #expect(helper["permissionMode"] as? String == "default")
            #expect(helper["maxTurns"] as? Int == 8)
            #expect(helper["background"] as? Bool == false)
            let denied = try #require(helper["disallowedTools"] as? [String])
            for tool in ["Agent", "Task", "TaskOutput", "TaskStop", "Skill", "mcp__*"] { #expect(denied.contains(tool)) }
            for key in ["isolation", "memory", "hooks", "mcpServers", "skills"] { #expect(helper[key] == nil) }
            let settings = try #require(JSONSerialization.jsonObject(with: Data(ClaudeTextOnlyCommandBuilder.settingsJSON(for: request).utf8)) as? [String: Any])
            let permissions = try #require(settings["permissions"] as? [String: Any])
            #expect(permissions["ask"] as? [String] == ["Agent"])
            #expect(!(permissions["deny"] as? [String] ?? []).contains("Task"))
            let environment = ClaudeTextOnlyCommandBuilder.environment(for: request)
            #expect(environment["CLAUDE_CODE_DISABLE_BACKGROUND_TASKS"] == "1")
            #expect(environment["CLAUDE_CODE_FORK_SUBAGENT"] == "0")
            #expect(environment["CLAUDE_AGENT_SDK_DISABLE_BUILTIN_AGENTS"] == "1")
        }
        let webOnly = try textOnlyTestRequest(allowedTools: [.webSearch])
        #expect(!ClaudeTextOnlyCommandBuilder.arguments(for: webOnly).contains("--agents"))
        #expect(ClaudeTextOnlyCommandBuilder.arguments(for: webOnly).contains("--safe-mode"))
        #expect(ClaudeTextOnlyCommandBuilder.environment(for: webOnly)["CLAUDE_CODE_FORK_SUBAGENT"] == nil)
    }

    @Test("A third helper is refused before an approval card or execution can begin")
    func budgetBeforePermission() throws {
        let request = try request(), control = ClaudeTextTurnControl()
        var stream = try ready(request, control: control)
        try approve(request, stream: &stream, control: control)
        try approve(request, stream: &stream, control: control, id: "helper-2")
        var emitted: [ClaudeTextOnlyEvent] = []
        #expect(throws: ClaudeTextOnlyRejection(failure: .turnLimitReached, code: .turnLimitReached)) {
            try stream.consume(permission(request, id: "helper-3")) { emitted.append($0) }
        }
        #expect(emitted.isEmpty)
    }

    @Test("Helper calls cannot change type, model, budget, resume, isolation or background behavior")
    func unsafeInputs() throws {
        let overrides: [[String: Any]] = [
            ["subagent_type": "general-purpose"], ["subagent_type": "fork"], ["model": "haiku"],
            ["resume": "old-agent"], ["run_in_background": true], ["run_in_background": 0],
            ["isolation": "worktree"], ["max_turns": 99], ["name": "worker"], ["team_name": "other"],
            ["prompt": ""], ["description": ""], ["mode": "bypassPermissions"]
        ]
        for override in overrides {
            let request = try request(), control = ClaudeTextTurnControl()
            var stream = try ready(request, control: control)
            var unsafe = input
            for (key, value) in override { unsafe[key] = value }
            var emitted: [ClaudeTextOnlyEvent] = []
            #expect(throws: ClaudeTextOnlyRejection.self) {
                try stream.consume(permission(request, input: unsafe)) { emitted.append($0) }
            }
            #expect(emitted.isEmpty)
        }
    }

    @Test("The helper assignment shown for approval must match the announced call exactly")
    func approvalInputBinding() throws {
        let request = try request(), control = ClaudeTextTurnControl()
        var stream = try ready(request, control: control)
        try stream.consume(announcement(request)) { _ in }
        var changed = input
        changed["prompt"] = "A different task"
        #expect(throws: ClaudeTextOnlyRejection.self) {
            try stream.consume(permission(request, input: changed)) { _ in }
        }
    }

    @Test("A helper's text and result never finish or pollute its parent's reply")
    func parentReplyIsolation() throws {
        let request = try request(), control = ClaudeTextTurnControl()
        var stream = try ready(request, control: control)
        try stream.consume(textOnlyTestDelta(request, text: "I am checking.")) { _ in }
        try approve(request, stream: &stream, control: control)
        var emitted: [ClaudeTextOnlyEvent] = []
        try stream.consume(textOnlyTestDelta(request, text: "PRIVATE HELPER TEXT", parent: "helper-1")) { emitted.append($0) }
        try stream.consume(textOnlyTestResult(request, override: ["parent_tool_use_id": "helper-1", "result": "HELPER RESULT"])) { emitted.append($0) }
        #expect(!stream.hasCompleted && stream.textSoFar == "I am checking." && emitted.isEmpty)
        try stream.consume(textOnlyTestDelta(request, text: " Compiled answer.")) { emitted.append($0) }
        try stream.consume(textOnlyTestResult(request, override: ["result": "I am checking. Compiled answer."])) { emitted.append($0) }
        #expect(stream.hasCompleted)
        #expect(emitted.last == .textSnapshot("I am checking. Compiled answer."))
    }

    @Test("Announcements, provider echoes and denied helper requests never authorize nested work")
    func unapprovedParents() throws {
        for allowQuestion in [false, true] {
            let request = try request(), control = ClaudeTextTurnControl()
            var stream = try ready(request, control: control)
            try stream.consume(announcement(request)) { _ in }
            if allowQuestion {
                try stream.consume(permission(request)) { if case .permissionRequested(let question) = $0 { control.register(question) } }
                #expect(control.respond(requestID: "ask-helper-1", allow: false))
            }
            #expect(throws: ClaudeTextOnlyRejection.self) {
                try stream.consume(textOnlyTestDelta(request, text: "unapproved", parent: "helper-1")) { _ in }
            }
        }
    }

    @Test("A helper cannot delegate, change its model, invent an agent identity or reuse a root tool identifier")
    func nestingAndIdentity() throws {
        let request = try request()
        for variant in 0..<4 {
            let control = ClaudeTextTurnControl()
            var stream = try ready(request, control: control)
            try approve(request, stream: &stream, control: control)
            let invalid: Data
            switch variant {
            case 0: invalid = try announcement(request, id: "nested", parent: "helper-1")
            case 1: invalid = try textOnlyTestLine(["type": "assistant", "session_id": request.sessionID.uuidString,
                "parent_tool_use_id": "helper-1", "message": ["role": "assistant", "model": "claude-haiku-4-5-20251001", "content": []]])
            case 2: invalid = try permission(request, id: "helper-2", agentID: "unknown-agent")
            default: invalid = try announcement(request, id: "helper-1", name: "Read", input: ["file_path": "a"], parent: "helper-1")
            }
            #expect(throws: ClaudeTextOnlyRejection.self) { try stream.consume(invalid) { _ in } }
        }
    }

    @Test("Approved helper child calls keep the same permission channel and tool result scope")
    func childActivity() throws {
        let request = try request(), control = ClaudeTextTurnControl()
        var stream = try ready(request, control: control)
        try approve(request, stream: &stream, control: control)
        try stream.consume(textOnlyTestLine(["type": "system", "subtype": "task_started", "session_id": request.sessionID.uuidString,
            "task_id": "agent-1", "tool_use_id": "helper-1", "task_type": "local_agent"])) { _ in }
        try stream.consume(announcement(request, id: "write-1", name: "Write", input: ["file_path": "report.md", "content": "draft"], parent: "helper-1")) { _ in }
        var events: [ClaudeTextOnlyEvent] = []
        try stream.consume(textOnlyTestLine(["type": "control_request", "request_id": "write-approval",
            "request": ["subtype": "can_use_tool", "tool_name": "Write", "tool_use_id": "write-1", "agent_id": "agent-1",
                        "input": ["file_path": "report.md", "content": "draft"]]])) { events.append($0) }
        #expect(events.count == 1)
        guard case .permissionRequested(let question) = events[0] else { Issue.record("Missing child permission"); return }
        #expect(question.toolName == "Write")
        try stream.consume(textOnlyTestLine(["type": "user", "session_id": request.sessionID.uuidString, "parent_tool_use_id": "helper-1",
            "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "write-1", "is_error": true, "content": "Denied"]]]])) { events.append($0) }
        #expect(events.last == .toolFinished(toolUseID: "write-1", failed: true))
        #expect(!stream.hasCompleted && stream.textSoFar.isEmpty)
    }

    @Test("A web tool's internal model and completion cannot replace the answering model")
    func webModelIsolation() throws {
        let request = try textOnlyTestRequest(allowedTools: [.webSearch])
        var stream = ClaudeTextOnlyStream(request: request)
        try stream.consume(textOnlyTestInit(request, override: ["tools": ["WebSearch"]])) { _ in }
        try stream.consume(textOnlyTestReplay(request)) { _ in }
        try stream.consume(announcement(request, id: "search-1", name: "WebSearch", input: ["query": "test"])) { _ in }
        try stream.consume(textOnlyTestLine(["type": "stream_event", "session_id": request.sessionID.uuidString,
            "parent_tool_use_id": "search-1", "event": ["type": "message_start",
                "message": ["role": "assistant", "model": "claude-haiku-4-5-20251001", "content": []]]])) { _ in }
        try stream.consume(textOnlyTestResult(request, override: ["parent_tool_use_id": "search-1", "result": "Tool summary",
            "modelUsage": ["claude-haiku-4-5-20251001": [:]]])) { _ in }
        #expect(!stream.hasCompleted)
        try stream.consume(textOnlyTestResult(request, override: ["result": "Parent answer"])) { _ in }
        #expect(stream.finish(exitCode: 0) == .success(.init(sessionID: request.sessionID,
            actualModel: request.expectedResolvedModel, text: "Parent answer", confirmedActualModel: request.expectedResolvedModel)))
    }

    @Test("Helper status patches remain bounded private metadata and cannot authorize background work")
    func helperStatusPatch() throws {
        let request = try request(), control = ClaudeTextTurnControl()
        var ready = try ready(request, control: control)
        try approve(request, stream: &ready, control: control)
        try ready.consume(textOnlyTestLine(["type": "system", "subtype": "task_started", "session_id": request.sessionID.uuidString,
            "task_id": "agent-1", "tool_use_id": "helper-1", "task_type": "local_agent"])) { _ in }
        func update(_ patch: [String: Any], task: String = "agent-1") throws -> Data {
            try textOnlyTestLine(["type": "system", "subtype": "task_updated", "session_id": request.sessionID.uuidString,
                "uuid": UUID().uuidString, "task_id": task, "patch": patch])
        }
        var stream = ready, events: [ClaudeTextOnlyEvent] = []
        try stream.consume(update(["status": "completed", "description": "PRIVATE", "error": "PRIVATE",
                                   "end_time": 12345, "total_paused_ms": 0, "is_backgrounded": false])) { events.append($0) }
        #expect(events.isEmpty && stream.textSoFar.isEmpty && !stream.hasCompleted && stream.grantedToolResultCount == 0)
        let invalid: [[String: Any]] = [["is_backgrounded": true], ["is_backgrounded": 0], ["status": "unknown"],
            ["end_time": -1], ["end_time": true], ["total_paused_ms": 0.5], ["description": []], ["command": "anything"], [:]]
        for patch in invalid {
            var attempt = ready
            #expect(throws: ClaudeTextOnlyRejection.self) { try attempt.consume(update(patch)) { _ in } }
        }
        #expect(throws: ClaudeTextOnlyRejection.self) { try stream.consume(update(["status": "running"], task: "unknown")) { _ in } }
        var bounded = ready
        for _ in 1..<ClaudeTextOnlyStream.maximumToolProgressFrames {
            try bounded.consume(update(["status": "running"])) { _ in }
        }
        #expect(throws: ClaudeTextOnlyRejection.self) { try bounded.consume(update(["status": "running"])) { _ in } }
    }

    @Test("Native transport carries a helper launch approval and its child's denial without exposing helper text")
    func nativeHelperRoundTrip() async throws {
        let template = try request()
        func emit(_ data: Data) -> String {
            "/bin/cat <<'OPENBOTS_SYNTHETIC_HELPER'\n" + String(decoding: data, as: UTF8.self) + "OPENBOTS_SYNTHETIC_HELPER"
        }
        let start = try textOnlyTestLine(["type": "system", "subtype": "task_started", "session_id": template.sessionID.uuidString,
            "task_id": "agent-1", "tool_use_id": "helper-1", "task_type": "local_agent"])
        let childQuestion = try textOnlyTestLine(["type": "control_request", "request_id": "child-write",
            "request": ["subtype": "can_use_tool", "tool_name": "Write", "tool_use_id": "write-1", "agent_id": "agent-1",
                        "input": ["file_path": "report.md", "content": "draft"]]])
        let childResult = try textOnlyTestLine(["type": "user", "session_id": template.sessionID.uuidString,
            "parent_tool_use_id": "helper-1", "message": ["role": "user",
                "content": [["type": "tool_result", "tool_use_id": "write-1", "is_error": true, "content": "Denied"]]]])
        let helperResult = try textOnlyTestLine(["type": "user", "session_id": template.sessionID.uuidString,
            "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "helper-1", "content": "Helper findings"]]]])
        let fixture = try ClaudeConnectionFixture(body: """
        IFS= read -r handshake
        request_id=$(printf '%s' "$handshake" | /usr/bin/sed -n 's/.*"request_id":"\\([^"]*\\)".*/\\1/p')
        printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{}}}\\n' "$request_id"
        IFS= read -r line
        \(emit(try textOnlyTestInit(template, override: ["tools": template.grantedToolNames, "permissionMode": "default"])))
        printf '{"isReplay":true,"parent_tool_use_id":null,%s\\n' "${line#?}"
        \(emit(try announcement(template)))
        \(emit(try permission(template)))
        IFS= read -r answer
        case "$answer" in *'"behavior":"allow"'*) ;; *) exit 41 ;; esac
        \(emit(start))
        \(emit(try helperReplay(template)))
        \(emit(try textOnlyTestLine(["type": "system", "subtype": "task_updated", "session_id": template.sessionID.uuidString,
            "uuid": UUID().uuidString, "task_id": "agent-1", "patch": ["status": "running"]])))
        \(emit(try announcement(template, id: "write-1", name: "Write", input: ["file_path": "report.md", "content": "draft"], parent: "helper-1")))
        \(emit(childQuestion))
        IFS= read -r child_answer
        case "$child_answer" in *'"behavior":"deny"'*) ;; *) exit 42 ;; esac
        \(emit(childResult))
        \(emit(try textOnlyTestDelta(template, text: "Hidden working text", parent: "helper-1")))
        \(emit(try textOnlyTestResult(template, override: ["parent_tool_use_id": "helper-1", "result": "Hidden helper result"])))
        \(emit(helperResult))
        \(emit(try textOnlyTestDelta(template, text: "Compiled answer.")))
        \(emit(try textOnlyTestResult(template, override: ["result": "Compiled answer."])))
        if IFS= read -r extra; then exit 43; fi
        """)
        defer { fixture.remove() }
        let access = try ClaudeTextWorkAccess(workingDirectoryURL: fixture.target.workingDirectoryURL,
                                             protectedPaths: template.workAccess!.protectedPaths)
        let request = try textOnlyTestRequest(target: fixture.target, workAccess: access)
        let control = ClaudeTextTurnControl()
        let result = await NativeClaudeTextOnlyRunner().run(request: request, control: control) { event in
            if case .permissionRequested(let question) = event {
                #expect(control.respond(requestID: question.requestID, allow: question.toolName == "Agent"))
            }
            if case .textSnapshot(let text) = event { #expect(!text.contains("Hidden")) }
        }
        #expect(result == .success(.init(sessionID: request.sessionID, actualModel: request.expectedResolvedModel,
            text: "Compiled answer.", confirmedActualModel: request.expectedResolvedModel)))
        #expect(!control.isAwaitingDecision)
    }
}
