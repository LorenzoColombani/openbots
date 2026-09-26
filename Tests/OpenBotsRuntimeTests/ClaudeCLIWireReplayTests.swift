import Foundation
import Testing
@testable import OpenBotsRuntime

// The installed CLI's real wire, replayed through the parser. Each fixture is a
// capture of `claude` launched with the app's own flags and environment
// (Tests/OpenBotsRuntimeTests/Fixtures/claude-cli-<version>/), values trimmed,
// paths and the account name replaced. The parser must accept every frame of
// every shape and finish the turn; a CLI update that changes the wire is then a
// red test with the frame named, not a dead turn in the installed app.
//
// Why this exists: when Claude Code 2.1.272 updated itself, every chat turn
// died at the first frame (a forced permission mode), and two team legs had
// died just before on a question about a tool no turn grants. Both were found by capturing the wire and replaying it
// here, not by reading the code.

private struct WireCapture {
    let shape: String
    let version: String
    let meta: [String: Any]
    let frames: [Data]

    init(version: String, shape: String) throws {
        self.shape = shape; self.version = version
        let folder = try #require(Bundle.module.url(forResource: "claude-cli-\(version)", withExtension: nil, subdirectory: "Fixtures"))
        meta = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("\(shape).meta.json"))) as? [String: Any])
        let text = try String(contentsOf: folder.appendingPathComponent("\(shape).frames.jsonl"), encoding: .utf8)
        frames = text.split(separator: "\n").map { Data(($0 + "\n").utf8) }
    }

    private init(shape: String, version: String, meta: [String: Any], frames: [Data]) {
        self.shape = shape; self.version = version; self.meta = meta; self.frames = frames
    }

    /// Where the CLI announced itself: the one `system/init` frame.
    var initFrameIndex: Int {
        get throws {
            try #require(frames.firstIndex { frame in
                let root = (try? JSONSerialization.jsonObject(with: frame) as? [String: Any]) ?? [:]
                return root["type"] as? String == "system" && root["subtype"] as? String == "init"
            })
        }
    }

    /// The same capture with its init frame changed the way a loosened CLI
    /// would change it: a skill, a slash command, an agent or an output style
    /// it found under the bot's folder and announced. Every other frame is
    /// byte for byte the capture, so a replay that gets past the init frame
    /// means the parser did not notice.
    func editingInit(_ edit: (inout [String: Any]) -> Void) throws -> WireCapture {
        let index = try initFrameIndex
        var root = try #require(JSONSerialization.jsonObject(with: frames[index]) as? [String: Any])
        edit(&root)
        var frame = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        frame.append(0x0a)
        var edited = frames
        edited[index] = frame
        return WireCapture(shape: shape, version: version, meta: meta, frames: edited)
    }

    func request() throws -> ClaudeTextOnlyRequest {
        let target = try ClaudeConnectionTarget(
            executableURL: URL(fileURLWithPath: "/private/tmp/not-created-text.noindex/claude"),
            expectedExecutableSHA256: String(repeating: "a", count: 64),
            profileURL: URL(fileURLWithPath: "/private/tmp/not-created-text.noindex/profile"),
            workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/not-created-text.noindex/work"),
            temporaryDirectoryURL: URL(fileURLWithPath: "/private/tmp/not-created-text.noindex/temp"),
            homeDirectoryURL: URL(fileURLWithPath: "/private/tmp/not-created-text.noindex/home"))
        let allowed: Set<ClaudeTextOnlyTool> = shape == "text" ? [] : [.webSearch, .webFetch]
        let cwd = try #require(meta["cwd"] as? String)
        let work = shape == "work" ? try ClaudeTextWorkAccess(workingDirectoryURL: URL(fileURLWithPath: cwd), protectedPaths: []) : nil
        let sessionText = try #require(meta["session_id"] as? String)
        let messageText = try #require(meta["message_id"] as? String)
        let sessionID = try #require(UUID(uuidString: sessionText))
        let messageID = try #require(UUID(uuidString: messageText))
        let prompt = try #require(meta["prompt"] as? String)
        let model = try #require(meta["model"] as? String)
        return try ClaudeTextOnlyRequest(target: target, runID: UUID(), sessionID: sessionID, messageID: messageID,
            text: prompt, systemPrompt: "probe", model: model, allowedTools: allowed, workAccess: work)
    }
}

private struct Replay {
    var rejections: [String] = []
    var events: [ClaudeTextOnlyEvent] = []
    var completed = false
    var text = ""
}

private func replay(_ capture: WireCapture, control: ClaudeTextTurnControl?,
                    answer: (ClaudeTextPermissionRequest) -> Bool) throws -> Replay {
    let request = try capture.request()
    var stream = ClaudeTextOnlyStream(request: request, control: control)
    if let id = capture.meta["control_id"] as? String, request.requiresPermissionControl {
        stream.expectControlInitialization(requestID: id)
    }
    var result = Replay()
    for (index, frame) in capture.frames.enumerated() {
        do {
            try stream.consume(frame) { event in
                result.events.append(event)
                if case .textSnapshot(let text) = event { result.text = text }
                if case .permissionRequested(let question) = event, let control {
                    control.register(question)
                    control.respond(requestID: question.requestID, allow: answer(question))
                }
            }
        } catch let rejection as ClaudeTextOnlyRejection {
            let root = (try? JSONSerialization.jsonObject(with: frame) as? [String: Any]) ?? [:]
            result.rejections.append("frame \(index + 1) \(rejection.failure)/\(rejection.code): \(ClaudeTextOnlyStream.shapeDescription(root))")
        }
    }
    result.completed = stream.hasCompleted
    return result
}

@Test("Claude Code 2.1.272: the shipped tool-free turn replays whole, forced default mode included")
func cli2_1_272TextTurnReplays() throws {
    let capture = try WireCapture(version: "2.1.272", shape: "text")
    let replay = try replay(capture, control: nil) { _ in false }
    #expect(replay.rejections.isEmpty, "\(replay.rejections)")
    #expect(replay.completed && replay.text.hasPrefix("Hello"))
}

@Test("Claude Code 2.1.272: a web turn replays whole, its search call announced and finished")
func cli2_1_272WebTurnReplays() throws {
    let capture = try WireCapture(version: "2.1.272", shape: "web")
    let replay = try replay(capture, control: nil) { _ in false }
    #expect(replay.rejections.isEmpty, "\(replay.rejections)")
    #expect(replay.completed && replay.text.contains("school.example"))
    #expect(replay.events.contains { if case .toolUse(let use) = $0 { return use.toolName == "WebSearch" }; return false })
}

@Test("Claude Code 2.1.272: a work turn with two helpers, a sandboxed shell and a network reach replays whole; the reach is a question the host denies")
func cli2_1_272WorkTurnReplays() throws {
    let capture = try WireCapture(version: "2.1.272", shape: "work")
    let control = ClaudeTextTurnControl()
    let quiet: Set<String> = ["Read", "Glob", "Grep", "WebSearch", "WebFetch", "Agent", "AskUserQuestion", "Write", "Edit"]
    let replay = try replay(capture, control: control) { question in question.admitted && quiet.contains(question.toolName) }
    #expect(replay.rejections.isEmpty, "\(replay.rejections)")
    #expect(replay.completed)
    let questions = replay.events.compactMap { event -> ClaudeTextPermissionRequest? in
        if case .permissionRequested(let question) = event { return question }; return nil
    }
    #expect(questions.map(\.toolName) == ["Agent", "Agent", "Bash", "SandboxNetworkAccess", "Bash", "Write"])
    #expect(questions.filter { !$0.admitted }.map(\.toolName) == ["SandboxNetworkAccess"])
    // The helpers' lifecycle frames, heartbeats and thinking estimates were all admitted, none of them as a reply.
    #expect(replay.events.contains { if case .toolUse(let use) = $0 { return use.toolName == "Agent" }; return false })
}

@Test("Claude Code 2.1.272: a skill, a slash command, an agent or an output style planted in a captured init frame is refused at that frame, in every shape, and so is a frame that stopped naming them")
func cli2_1_272PlantedInitFrameIsRefused() throws {
    // Nothing loads from a folder on any shape: the command disables memory
    // files, settings sources, slash commands and the Skill tool, and defines
    // the one helper itself. A quiet write inside the bot's folder can plant
    // .claude/skills, .claude/commands or .claude/agents there all the same,
    // so the wire has to say they stayed unloaded — and a CLI that stops
    // saying so is not trusted either.
    let everyShape: [(String, (inout [String: Any]) -> Void)] = [
        ("a skill", { $0["skills"] = ["planted-skill"] }),
        ("a slash command", { $0["slash_commands"] = ["planted-command"] }),
        ("an output style", { $0["output_style"] = "planted-style" }),
        ("no skills key", { $0["skills"] = nil }),
        ("no slash commands key", { $0["slash_commands"] = nil }),
        ("no agents key", { $0["agents"] = nil }),
        ("no output style key", { $0["output_style"] = nil }),
    ]
    for shape in ["text", "web", "work"] {
        let capture = try WireCapture(version: "2.1.272", shape: shape)
        var plants = everyShape
        if shape == "work" {
            plants += [("a second agent beside the helper", { $0["agents"] = ["openbots-helper", "planted-agent"] }),
                       ("another agent instead of the helper", { $0["agents"] = ["planted-agent"] }),
                       ("no helper where one was defined", { $0["agents"] = [] })]
        } else {
            plants += [("a helper the command never defined", { $0["agents"] = ["openbots-helper"] })]
        }
        for (plant, edit) in plants {
            let planted = try capture.editingInit(edit)
            let control = shape == "work" ? ClaudeTextTurnControl() : nil
            let replay = try replay(planted, control: control) { _ in false }
            let expected = "frame \(try planted.initFrameIndex + 1) unsafeInitialization/initializationExtensionsInvalid"
            #expect(replay.rejections.first?.hasPrefix(expected) == true,
                    "\(shape) with \(plant): first rejection \(replay.rejections.first ?? "none")")
            #expect(!replay.completed, "\(shape) with \(plant) finished the turn")
        }
    }
}

// When Claude Code 2.1.281 updated itself, every turn died at the init frame:
// it announced a built-in plugin, agents-md, that loads a folder's agent
// instruction files where CLAUDE.md would. The settings now switch it off
// (`enabledPlugins`), and these captures were made with that setting and a
// canary instruction file in the bot's folder and in a subfolder the work turn
// read; the canary never reached the model.
@Test("Claude Code 2.1.281: the tool-free turn and a work turn replay whole with the built-in plugin off")
func cli2_1_281TurnsReplay() throws {
    let text = try WireCapture(version: "2.1.281", shape: "text")
    let textReplay = try replay(text, control: nil) { _ in false }
    #expect(textReplay.rejections.isEmpty, "\(textReplay.rejections)")
    #expect(textReplay.completed && textReplay.text.hasPrefix("NONE"))

    let work = try WireCapture(version: "2.1.281", shape: "work")
    let quiet: Set<String> = ["Read", "Glob", "Grep"]
    let workReplay = try replay(work, control: ClaudeTextTurnControl()) { $0.admitted && quiet.contains($0.toolName) }
    #expect(workReplay.rejections.isEmpty, "\(workReplay.rejections)")
    #expect(workReplay.completed && workReplay.text.contains("NONE") && workReplay.text.contains("tea"))
}

@Test("Claude Code 2.1.281: an init frame that still announces the agents-md plugin is refused at that frame")
func cli2_1_281AgentsMdPluginIsRefused() throws {
    for shape in ["text", "work"] {
        let planted = try WireCapture(version: "2.1.281", shape: shape).editingInit {
            $0["plugins"] = [["name": "agents-md", "path": "builtin", "source": "agents-md@builtin"]]
        }
        let replay = try replay(planted, control: shape == "work" ? ClaudeTextTurnControl() : nil) { _ in false }
        #expect(replay.rejections.first?.contains("initializationPluginsInvalid") == true, "\(shape): \(replay.rejections)")
        #expect(!replay.completed)
    }
}

// This Claude Code 2.1.282 capture was made with the app's environment, the
// refusal fallback switched off.
@Test("Claude Code 2.1.282: the tool-free turn replays whole with the refusal fallback switched off")
func cli2_1_282TextTurnReplays() throws {
    let text = try WireCapture(version: "2.1.282", shape: "text")
    let replay = try replay(text, control: nil) { _ in false }
    #expect(replay.rejections.isEmpty, "\(replay.rejections)")
    #expect(replay.completed && replay.text.hasPrefix("NONE"))
}

// The refusal itself is not captured: a provider refusal is not something to
// provoke. Its two frames are built from the 2.1.282 bundle's stream-json
// serializer and set into the captured turn after its first words, where the
// CLI's main loop yields them; every other frame is the capture's own.
@Test("Claude Code 2.1.282: the refusal frames the bundle writes, set into the captured turn, end it as declined, never as an app fault")
func cli2_1_282RefusalReplaysAsDeclined() throws {
    let capture = try WireCapture(version: "2.1.282", shape: "text")
    let request = try capture.request()
    let roots = capture.frames.map { (try? JSONSerialization.jsonObject(with: $0) as? [String: Any]) ?? [:] }
    let firstWords = try #require(roots.firstIndex {
        ($0["event"] as? [String: Any])?["type"] as? String == "content_block_delta"
    })
    let result = try #require(roots.firstIndex { $0["type"] as? String == "result" })
    func line(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]); data.append(0x0a); return data
    }
    let session = request.sessionID.uuidString.lowercased()
    let stop = try line(["type": "stream_event", "session_id": session, "parent_tool_use_id": NSNull(),
        "uuid": UUID().uuidString.lowercased(),
        "event": ["type": "message_delta", "delta": ["stop_reason": "refusal", "stop_sequence": NSNull(),
                                                     "stop_details": NSNull(), "container": NSNull()]]])
    let noFallback = try line(["type": "system", "subtype": "model_refusal_no_fallback", "uuid": UUID().uuidString.lowercased(),
        "session_id": session, "original_model": request.expectedResolvedModel, "request_id": "req_011CfPtvso4KShikxL4bzAwN",
        "api_refusal_category": NSNull(), "api_refusal_explanation": NSNull(), "refused_user_message_uuid": NSNull(),
        "content": ""])
    let frames = Array(capture.frames[...firstWords]) + [stop, noFallback] + [capture.frames[result]]
    var stream = ClaudeTextOnlyStream(request: request)
    for frame in frames { try stream.consume(frame) { _ in } }
    #expect(stream.hasCompleted)
    var diagnostics: [ClaudeTextOnlyDiagnosticCode] = []
    #expect(stream.finish(exitCode: 0) { diagnostics.append($0) } == .failed(.declined))
    #expect(diagnostics.isEmpty)

    // The frame that hands the reply to another model ends the turn at once.
    let fallback = try line(["type": "system", "subtype": "model_refusal_fallback", "uuid": UUID().uuidString.lowercased(),
        "session_id": session, "trigger": "refusal", "direction": "retry", "scope": "local",
        "original_model": request.expectedResolvedModel, "fallback_model": "claude-opus-5", "request_id": "req_1",
        "api_refusal_category": NSNull(), "api_refusal_explanation": NSNull(), "refused_user_message_uuid": NSNull(),
        "content": "Retried on another model."])
    var handed = ClaudeTextOnlyStream(request: request)
    for frame in capture.frames[...firstWords] { try handed.consume(frame) { _ in } }
    #expect(throws: ClaudeTextOnlyRejection(failure: .declined, code: .unexpectedSystemEvent)) {
        try handed.consume(fallback) { _ in }
    }
}
