import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsRuntime

// A bot without Work reads the shared folder and its skills.
// Its turn keeps the tool-free turn's own flags (--safe-mode, --restricted, dontAsk, no permission
// channel), so every refusal is the CLI's own. The real wire of that shape, replayed through the
// parser (Fixtures/claude-cli-2.1.272/read-probe, captured with the Shared and Skills folders as
// read folders, a protected folder and an `appsupport` folder as protected roots, no allow rule as
// the app writes none, and a run folder inside `appsupport` as the working folder, as the app's run
// folder sits inside its own Application Support root; local paths scrubbed):
//   r2-read-refusals  a read inside the shared folder; a Read outside the folders (a
//                     `permission_denied` frame, --restricted); a Read under a protected root (no
//                     frame, only a failed result); a Glob and a Grep with no path, which search
//                     the turn's working folder under the app's own data and are refused by rule
//                     (a `permission_denied` frame each). The result lists all four denials.

private struct ReadProbeCapture {
    let sessionID: UUID
    let messageID: UUID
    let prompt: String
    let model: String
    /// The CLI's frames, in arrival order.
    let frames: [Data]

    init(run: String) throws {
        let root = try #require(Bundle.module.url(forResource: "claude-cli-2.1.272", withExtension: nil, subdirectory: "Fixtures"))
        let folder = root.appendingPathComponent("read-probe").appendingPathComponent(run)
        let argv = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("argv.json"))) as? [String: Any])
        let meta = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("meta.json"))) as? [String: Any])
        let session = try #require(argv["session_id"] as? String)
        let message = try #require(argv["message_id"] as? String)
        sessionID = try #require(UUID(uuidString: session))
        messageID = try #require(UUID(uuidString: message))
        prompt = try #require(meta["prompt"] as? String)
        model = try #require(meta["model"] as? String)
        var frames: [Data] = []
        for line in try String(contentsOf: folder.appendingPathComponent("wire.jsonl"), encoding: .utf8).split(separator: "\n") {
            let record = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            // The host's only line on this shape is the user message it wrote.
            guard record["dir"] as? String == "cli", var frame = record["frame"] as? [String: Any] else { continue }
            // The scrubber redacts the key source by its name; the app's own launch reports "none".
            if frame["type"] as? String == "system", frame["subtype"] as? String == "init",
               frame["apiKeySource"] as? String == "redacted" { frame["apiKeySource"] = "none" }
            var data = try JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys])
            data.append(0x0a)
            frames.append(data)
        }
        self.frames = frames
    }

    /// The app's request for a reading turn: the shared and skills folders, the protected roots.
    /// The paths stand in for the probe's `$RUN` folders, which no stream check reads.
    func request() throws -> ClaudeTextOnlyRequest {
        let read = try ClaudeTextReadAccess(sharedDirectoryURL: URL(fileURLWithPath: "/private/tmp/read-probe.noindex/Shared"),
            skillsDirectoryURL: URL(fileURLWithPath: "/private/tmp/read-probe.noindex/Skills"),
            protectedPaths: ["/private/tmp/read-probe.noindex/protected", "/private/tmp/read-probe.noindex/appsupport"])
        let target = try ClaudeConnectionTarget(
            executableURL: URL(fileURLWithPath: "/private/tmp/not-created-text.noindex/claude"),
            expectedExecutableSHA256: String(repeating: "a", count: 64),
            profileURL: URL(fileURLWithPath: "/private/tmp/not-created-text.noindex/profile"),
            workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/not-created-text.noindex/work"),
            temporaryDirectoryURL: URL(fileURLWithPath: "/private/tmp/not-created-text.noindex/temp"),
            homeDirectoryURL: URL(fileURLWithPath: "/private/tmp/not-created-text.noindex/home"))
        return try ClaudeTextOnlyRequest(target: target, runID: UUID(), sessionID: sessionID, messageID: messageID,
            text: prompt, systemPrompt: "probe", model: model, readAccess: read)
    }
}

private struct ReadReplay {
    var rejections: [String] = []
    var events: [ClaudeTextOnlyEvent] = []
    var completed = false
    var result: ClaudeTextOnlyResult?
}

/// Every frame through the stream, as the transport feeds it, recording a rejection instead of stopping.
private func replay(_ request: ClaudeTextOnlyRequest, frames: [Data]) -> ReadReplay {
    var stream = ClaudeTextOnlyStream(request: request)
    var replay = ReadReplay()
    for (index, frame) in frames.enumerated() {
        do {
            try stream.consume(frame) { replay.events.append($0) }
        } catch let rejection as ClaudeTextOnlyRejection {
            let root = (try? JSONSerialization.jsonObject(with: frame) as? [String: Any]) ?? [:]
            replay.rejections.append("frame \(index + 1) \(rejection.failure)/\(rejection.code): \(ClaudeTextOnlyStream.shapeDescription(root))")
        } catch {
            replay.rejections.append("frame \(index + 1) \(error)")
        }
    }
    replay.completed = stream.hasCompleted
    replay.result = stream.finish(exitCode: 0)
    return replay
}

@Test("Claude Code 2.1.272: a reading turn without Work replays whole; the CLI's own refusals of an outside, a protected and two pathless reads become events and the reply arrives")
func cli2_1_272ReadingTurnWithRefusalsReplays() throws {
    let capture = try ReadProbeCapture(run: "r2-read-refusals")
    let request = try capture.request()
    #expect(request.grantsReading && !request.requiresPermissionControl && !request.grantsWork)
    let replay = replay(request, frames: capture.frames)
    #expect(replay.rejections.isEmpty, "\(replay.rejections)")
    #expect(replay.completed)
    guard case .success(let reply) = replay.result else { Issue.record("the turn did not finish: \(String(describing: replay.result))"); return }
    #expect(reply.text.contains("COPPER-WREN"))
    // The three calls the CLI refused with a frame, in order: the outside Read, the pathless Glob, the pathless Grep.
    let refused = replay.events.compactMap { event -> String? in
        if case .toolRefused(let id, let name) = event { return "\(name) \(id)" }; return nil
    }
    #expect(refused == ["Read toolu_01Qc6QBeuYaHrQdjGdtiPaSo", "Glob toolu_01G1kkLG5HjHFujet1Q8PcnY", "Grep toolu_01TrmCmMGAmBALfsR4K3HjAS"])
    // Every call's result: the read inside ran; the four refused calls, the protected Read among them, failed.
    let finished = replay.events.compactMap { event -> String? in
        if case .toolFinished(let id, let failed) = event { return "\(id) \(failed ? "failed" : "ran")" }; return nil
    }
    #expect(finished == ["toolu_01BGnnZjUFxRb9U2e5ptatYb ran", "toolu_01Qc6QBeuYaHrQdjGdtiPaSo failed",
                         "toolu_014RTZ8FgXWMChXokbNxE4Qe failed", "toolu_01G1kkLG5HjHFujet1Q8PcnY failed",
                         "toolu_01TrmCmMGAmBALfsR4K3HjAS failed"])
}

@Test("A reading turn without a card admits the CLI's refusals of its three read tools only: a refused web call, or a result denying one, still ends the turn")
func readingTurnAdmitsOnlyReadRefusals() throws {
    let read = try ClaudeTextReadAccess(sharedDirectoryURL: URL(fileURLWithPath: "/private/tmp/read-probe.noindex/Shared"), protectedPaths: [])
    let request = try textOnlyTestRequest(allowedTools: [.webFetch], readAccess: read)
    #expect(request.grantsReading && !request.requiresPermissionControl)
    // Initialized, the input replayed, and one round announcing a read and a web call.
    func ready() throws -> ClaudeTextOnlyStream {
        var stream = ClaudeTextOnlyStream(request: request)
        try stream.consume(textOnlyTestInit(request, override: ["tools": request.grantedToolNames, "permissionMode": "default"])) { _ in }
        try stream.consume(textOnlyTestReplay(request)) { _ in }
        try stream.consume(textOnlyTestLine(["type": "assistant", "session_id": request.sessionID.uuidString,
            "message": ["role": "assistant", "model": request.expectedResolvedModel, "content": [
                ["type": "tool_use", "id": "toolu_read", "name": "Grep", "input": ["pattern": "COPPER"]],
                ["type": "tool_use", "id": "toolu_web", "name": "WebFetch", "input": ["url": "https://example.com", "prompt": "Summarize"]]]]])) { _ in }
        try stream.consume(textOnlyTestDelta(request, text: "Hello back")) { _ in }
        return stream
    }
    // The shape 2.1.272 sends when a rule refuses a Grep with no path (read-probe/r2-read-refusals).
    func refusal(_ tool: String, _ id: String) throws -> Data {
        try textOnlyTestLine(["type": "system", "subtype": "permission_denied", "session_id": request.sessionID.uuidString,
            "uuid": UUID().uuidString, "tool_name": tool, "tool_use_id": id, "decision_reason_type": "rule",
            "message": "Permission to read /private/tmp/read-probe.noindex/appsupport has been denied."])
    }
    var stream = try ready()
    var events: [ClaudeTextOnlyEvent] = []
    try stream.consume(refusal("Grep", "toolu_read")) { events.append($0) }
    #expect(events == [.toolRefused(toolUseID: "toolu_read", toolName: "Grep")])
    try stream.consume(textOnlyTestResult(request, override: [
        "permission_denials": [["tool_name": "Grep", "tool_use_id": "toolu_read", "tool_input": ["pattern": "COPPER"]]]])) { _ in }
    #expect(stream.hasCompleted)
    // A web call is never refused on this turn's account: nothing here could have asked about it.
    var web = try ready()
    #expect(throws: ClaudeTextOnlyRejection.self) { try web.consume(refusal("WebFetch", "toolu_web")) { _ in } }
    // A result denying anything but a read, or a denial naming no tool, is not a reply.
    let denials: [[[String: Any]]] = [[["tool_name": "WebFetch", "tool_use_id": "toolu_web"]],
                                      [["tool_name": "Grep", "tool_use_id": "toolu_read"], ["tool_use_id": "toolu_web"]]]
    for denial in denials {
        var ended = try ready()
        let rejection = #expect(throws: ClaudeTextOnlyRejection.self, "\(denial)") {
            try ended.consume(textOnlyTestResult(request, override: ["permission_denials": denial])) { _ in }
        }
        #expect(rejection?.failure == .providerFailed, "\(denial)")
        #expect(!ended.hasCompleted)
    }
}

// A member's leg that only reads and browses, if launched with the web
// pre-allowed in its settings and no channel to ask, would keep the fence its
// lead's Contacts read put on the chain from ever reaching the CLI. So a turn
// whose web must ask carries the asking channel whatever else
// it holds, and its settings pre-allow no web tool.
@Test("A turn that must ask before the web is launched to ask: the control channel, the default mode, and no web tool pre-allowed anywhere",
      arguments: [true, false])
func aFencedBrowsingTurnAsksBeforeTheWeb(_ reads: Bool) throws {
    let read = try ClaudeTextReadAccess(sharedDirectoryURL: URL(fileURLWithPath: "/private/tmp/read-probe.noindex/Shared"), protectedPaths: [])
    let request = try textOnlyTestRequest(allowedTools: [.webSearch, .webFetch], readAccess: reads ? read : nil,
                                          sessionHoldsPrivateRead: true)
    #expect(request.asksBeforeWeb && request.requiresPermissionControl)
    let arguments = ClaudeTextOnlyCommandBuilder.arguments(for: request)
    #expect(arguments.contains("--permission-prompt-tool"))
    let mode = try #require(arguments.firstIndex(of: "--permission-mode"))
    #expect(arguments[mode + 1] == "default")
    let settings = try #require(arguments.firstIndex(of: "--settings"))
    let object = try #require(try JSONSerialization.jsonObject(with: Data(arguments[settings + 1].utf8)) as? [String: Any])
    let permissions = try #require(object["permissions"] as? [String: Any])
    #expect(permissions["defaultMode"] as? String == "default")
    let allowed = permissions["allow"] as? [String] ?? []
    #expect(!allowed.contains("WebSearch") && !allowed.contains("WebFetch"), "\(allowed)")
    let denied = permissions["deny"] as? [String] ?? []
    #expect(!denied.contains("WebSearch") && !denied.contains("WebFetch"), "\(denied)")
    if let allowedFlag = arguments.firstIndex(of: "--allowedTools") {
        #expect(!arguments[allowedFlag + 1].contains("Web"), "\(arguments[allowedFlag + 1])")
    }
    // The same turn without the fence keeps its shipped shape.
    let open = try textOnlyTestRequest(allowedTools: [.webSearch, .webFetch], readAccess: reads ? read : nil)
    #expect(!open.asksBeforeWeb && !open.requiresPermissionControl)
    #expect(!ClaudeTextOnlyCommandBuilder.arguments(for: open).contains("--permission-prompt-tool"))
}
