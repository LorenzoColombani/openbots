import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsRuntime

// The hire carrier's real wire, replayed through the parser and the host's
// answers. Each fixture is one recorded probe run of Claude Code 2.1.272 with the
// app's flags and the app's own MCP server, `openbots`, answered by the probe host:
//   a2-ask        work + hire, no allow rule: a question first, then the call
//   a3-allow      work + hire, the exact allow rule: the call with no question
//   a5-faults     work + hire: a timeout, an error, an empty answer, then a hire
//   a10-refusals  work + hire: a refused result, a JSON-RPC error, two hires
//   a12-hire-only the hire grant alone, in the connector-turn shape
//   a13-hire-only-reads
//                 the same turn once every bot reads: the shared and skills
//                 folders added, a protected root denied by rule
//   a14-hire-beside-connector
//                 the launch of a bot with a connector and the hire switch: one
//                 stdio connector keyed as the app keys them, in a
//                 configuration file, beside the hire server; reading added
// The parser must take every frame the CLI wrote and finish the turn, and the
// host must answer every server message the way the probe's host did.

private struct HireProbeCapture {
    let run: String
    let shape: String
    let sessionID: UUID
    let messageID: UUID
    let controlID: String
    let prompt: String
    let model: String
    /// The launch added folders to read (`--add-dir`), as a turn without Work that reads does.
    let readsFolders: Bool
    /// The connector server the launch carried beside the hire server, by its key.
    let connectorName: String?
    /// The CLI's frames, in arrival order.
    let frames: [Data]

    init(run: String) throws {
        self.run = run
        let root = try #require(Bundle.module.url(forResource: "claude-cli-2.1.272", withExtension: nil, subdirectory: "Fixtures"))
        let folder = root.appendingPathComponent("hire-probe").appendingPathComponent(run)
        let argv = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("argv.json"))) as? [String: Any])
        let meta = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("meta.json"))) as? [String: Any])
        shape = try #require(argv["shape"] as? String)
        let session = try #require(argv["session_id"] as? String)
        let message = try #require(argv["message_id"] as? String)
        sessionID = try #require(UUID(uuidString: session))
        messageID = try #require(UUID(uuidString: message))
        controlID = try #require(argv["control_id"] as? String)
        prompt = try #require(meta["prompt"] as? String)
        model = try #require(meta["model"] as? String)
        readsFolders = try #require(argv["argv"] as? [String]).contains("--add-dir")
        connectorName = (argv["connector"] as? [String: Any])?["name"] as? String
        let lines = try String(contentsOf: folder.appendingPathComponent("wire.jsonl"), encoding: .utf8)
            .split(separator: "\n")
        var statusRequests: Set<String> = []
        var frames: [Data] = []
        for line in lines {
            let record = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            // A line with no frame is the probe host's own note ("withheld").
            guard var frame = record["frame"] as? [String: Any] else { continue }
            if record["dir"] as? String == "host" {
                // The probe asked the CLI for `mcp_status` to watch the server;
                // the app never does, so that answer is not part of its wire.
                if (frame["request"] as? [String: Any])?["subtype"] as? String == "mcp_status",
                   let id = frame["request_id"] as? String { statusRequests.insert(id) }
                continue
            }
            if frame["type"] as? String == "control_response",
               let id = (frame["response"] as? [String: Any])?["request_id"] as? String, statusRequests.contains(id) { continue }
            // The probe redacted the key source; the app's own launch reports "none".
            if frame["type"] as? String == "system", frame["subtype"] as? String == "init",
               frame["apiKeySource"] as? String == "redacted" { frame["apiKeySource"] = "none" }
            var data = try JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys])
            data.append(0x0a)
            frames.append(data)
        }
        self.frames = frames
    }

    /// The app's request for this run's shape. A synthetic working directory
    /// stands in for the probe's `$RUN/botfolder`, which no stream check reads.
    func request(grantsHiring: Bool = true, reads: Bool? = nil, connector: Bool = true) throws -> ClaudeTextOnlyRequest {
        let target = try ClaudeConnectionTarget(
            executableURL: URL(fileURLWithPath: "/private/tmp/not-created-text.noindex/claude"),
            expectedExecutableSHA256: String(repeating: "a", count: 64),
            profileURL: URL(fileURLWithPath: "/private/tmp/not-created-text.noindex/profile"),
            workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/not-created-text.noindex/work"),
            temporaryDirectoryURL: URL(fileURLWithPath: "/private/tmp/not-created-text.noindex/temp"),
            homeDirectoryURL: URL(fileURLWithPath: "/private/tmp/not-created-text.noindex/home"))
        let work = shape == "hire"
            ? try ClaudeTextWorkAccess(workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/hire-probe.noindex/botfolder"), protectedPaths: [])
            : nil
        let read = reads ?? readsFolders
            ? try ClaudeTextReadAccess(sharedDirectoryURL: URL(fileURLWithPath: "/private/tmp/hire-probe.noindex/Shared"),
                                       skillsDirectoryURL: URL(fileURLWithPath: "/private/tmp/hire-probe.noindex/Skills"),
                                       protectedPaths: ["/private/tmp/hire-probe.noindex/protected"])
            : nil
        // The server's key is what the stream admits by; its role only chooses a card's words.
        let connectors = try connectorName.flatMap { name in connector ? name : nil }.map { name in
            try ClaudeTextConnectorAccess(servers: [ClaudeTextConnectorServer(name: name, role: .browser,
                program: .installedTool(URL(fileURLWithPath: "/private/tmp/hire-probe.noindex/echo-server")),
                options: [], environment: [:])])
        }
        return try ClaudeTextOnlyRequest(target: target, runID: UUID(), sessionID: sessionID, messageID: messageID,
            text: prompt, systemPrompt: "probe", model: model, workAccess: work, connectorAccess: connectors,
            grantsHiring: grantsHiring, readAccess: read)
    }

    func editing(_ index: Int, _ edit: (inout [String: Any]) -> Void) throws -> [Data] {
        var root = try #require(JSONSerialization.jsonObject(with: frames[index]) as? [String: Any])
        edit(&root)
        var frame = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        frame.append(0x0a)
        var edited = frames
        edited[index] = frame
        return edited
    }

    func index(where predicate: ([String: Any]) -> Bool) throws -> Int {
        try #require(frames.firstIndex { frame in
            predicate((try? JSONSerialization.jsonObject(with: frame) as? [String: Any]) ?? [:])
        })
    }
}

private struct HireReplay {
    var rejections: [String] = []
    var events: [ClaudeTextOnlyEvent] = []
    var answers: [[String: Any]] = []
    var completed = false
    var text = ""
    var calls: [ClaudeTextHireCall] {
        events.compactMap { if case .hireRequested(let call) = $0 { return call }; return nil }
    }
}

/// Every frame through the stream, as the transport feeds it; every question
/// about the hire tool allowed, as the service does; every hire call answered.
private func replay(_ capture: HireProbeCapture, frames: [Data]? = nil, grantsHiring: Bool = true, reads: Bool? = nil,
                    allowsHelpers: Bool = false, connector: Bool = true,
                    answer: (ClaudeTextHireCall) -> (String, Bool) = { _ in ("Hired @scout: Price watching.", false) }) throws -> HireReplay {
    let request = try capture.request(grantsHiring: grantsHiring, reads: reads, connector: connector)
    let control = ClaudeTextTurnControl()
    var stream = ClaudeTextOnlyStream(request: request, control: control)
    stream.expectControlInitialization(requestID: capture.controlID)
    var result = HireReplay()
    for (index, frame) in (frames ?? capture.frames).enumerated() {
        do {
            try stream.consume(frame) { event in
                result.events.append(event)
                if case .textSnapshot(let text) = event { result.text = text }
                if case .permissionRequested(let question) = event {
                    control.register(question)
                    control.respond(requestID: question.requestID,
                                    allow: question.admitted && (question.toolName == ClaudeTextHirePolicy.qualifiedToolName
                                        || (allowsHelpers && question.toolName == ClaudeTextHelperPolicy.toolName)
                                        || request.connectorAccess?.admitsToolName(question.toolName) == true))
                }
                if case .hireRequested(let call) = event {
                    let (text, refused) = answer(call)
                    control.answerHire(requestID: call.requestID, text: text, refused: refused)
                }
            }
        } catch let rejection as ClaudeTextOnlyRejection {
            let root = (try? JSONSerialization.jsonObject(with: frame) as? [String: Any]) ?? [:]
            result.rejections.append("frame \(index + 1) \(rejection.failure)/\(rejection.code): \(ClaudeTextOnlyStream.shapeDescription(root))")
        }
        for data in control.takePending() {
            if let answer = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { result.answers.append(answer) }
        }
    }
    result.completed = stream.hasCompleted
    return result
}

/// Each server message the CLI sent, by control request id, with its JSON-RPC message.
private func serverMessages(_ capture: HireProbeCapture) -> [(requestID: String, message: [String: Any])] {
    capture.frames.compactMap { frame in
        guard let root = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
              root["type"] as? String == "control_request",
              let request = root["request"] as? [String: Any], request["subtype"] as? String == "mcp_message",
              let id = root["request_id"] as? String, let message = request["message"] as? [String: Any] else { return nil }
        return (id, message)
    }
}

/// Every server message has exactly one answer, under its own request id,
/// carrying `mcp_response` with the message's JSON-RPC id (0 for a notification).
private func expectOneAnswerEach(_ replay: HireReplay, _ capture: HireProbeCapture) throws {
    let messages = serverMessages(capture)
    let requestIDs = Set(messages.map(\.requestID))
    // A permission answer (a2's question) is the channel's other traffic, not the server's.
    let serverAnswers = replay.answers.filter {
        requestIDs.contains((($0["response"] as? [String: Any])?["request_id"] as? String) ?? "")
    }
    #expect(serverAnswers.count == messages.count, "\(capture.run): \(serverAnswers.count) answers for \(messages.count) messages")
    for (requestID, message) in messages {
        let matching = replay.answers.filter { (($0["response"] as? [String: Any])?["request_id"] as? String) == requestID }
        #expect(matching.count == 1, "\(capture.run): \(matching.count) answers to \(message["method"] ?? "?")")
        guard let answer = matching.first,
              let body = (answer["response"] as? [String: Any])?["response"] as? [String: Any],
              let reply = body["mcp_response"] as? [String: Any] else {
            Issue.record("\(capture.run): no mcp_response for \(message["method"] ?? "?")"); continue
        }
        #expect(Set(body.keys) == ["mcp_response"])
        #expect((reply["id"] as? Int) == ((message["id"] as? Int) ?? 0))
    }
}

@Test("Claude Code 2.1.272: a hire-only turn replays whole; the handshake, the list and the one call are answered, the call keyed to its tool use")
func cli2_1_272HireOnlyTurnReplays() throws {
    let capture = try HireProbeCapture(run: "a12-hire-only")
    #expect(capture.shape == "hire-only")
    let replay = try replay(capture)
    #expect(replay.rejections.isEmpty, "\(replay.rejections)")
    #expect(replay.completed)
    try expectOneAnswerEach(replay, capture)
    let call = try #require(replay.calls.first)
    #expect(replay.calls.count == 1)
    #expect(call.isOwnCall, "the bot's own reply announced this call")
    #expect(call.toolUseID.hasPrefix("toolu_"))
    let arguments = try #require(JSONSerialization.jsonObject(with: call.argumentsJSON) as? [String: String])
    #expect(arguments == ["handle": "scout", "purpose": "Price watching"])
    #expect(replay.events.contains { if case .toolUse(let use) = $0 { return use.id == call.toolUseID && use.toolName == ClaudeTextHirePolicy.qualifiedToolName }; return false })
    #expect(replay.events.contains { if case .toolFinished(let id, let failed) = $0 { return id == call.toolUseID && !failed }; return false })
    // The initialize answer echoes the protocol the CLI asked for.
    let initialize = try #require(replay.answers.first)
    let result = ((((initialize["response"] as? [String: Any])?["response"] as? [String: Any])?["mcp_response"] as? [String: Any])?["result"] as? [String: Any])
    #expect(result?["protocolVersion"] as? String == "2025-11-25")
}

@Test("Claude Code 2.1.272: a hire-only turn that reads replays whole; the read inside runs, the CLI refuses the outside and protected reads itself, the hire call is answered")
func cli2_1_272HireOnlyTurnThatReadsReplays() throws {
    let capture = try HireProbeCapture(run: "a13-hire-only-reads")
    #expect(capture.shape == "hire-only")
    #expect(capture.readsFolders)
    let replay = try replay(capture)
    #expect(replay.rejections.isEmpty, "\(replay.rejections)")
    #expect(replay.completed)
    try expectOneAnswerEach(replay, capture)
    #expect(replay.calls.count == 1)
    #expect(replay.calls.allSatisfy { $0.isOwnCall })
    // No question reached the host: both refusals were the CLI's own.
    #expect(!replay.events.contains { if case .permissionRequested = $0 { return true }; return false })
    let reads = replay.events.compactMap { event -> String? in
        if case .toolUse(let use) = event, use.toolName == "Read" { return use.id }; return nil
    }
    let failures = Dictionary(replay.events.compactMap { event -> (String, Bool)? in
        if case .toolFinished(let id, let failed) = event { return (id, failed) }; return nil
    }, uniquingKeysWith: { first, _ in first })
    #expect(reads.map { failures[$0] } == [false, true, true], "inside, outside, protected")
}

@Test("Claude Code 2.1.272: the reading hire-only wire on a turn launched without reading is refused at its init frame")
func cli2_1_272ReadingHireWireWithoutReadingIsRefused() throws {
    let capture = try HireProbeCapture(run: "a13-hire-only-reads")
    let initIndex = try capture.index { $0["type"] as? String == "system" && $0["subtype"] as? String == "init" }
    // The app ends the turn at its first rejection, so the replay stops at the init frame:
    // the server's handshake before it is taken, the frame itself is not.
    let replay = try replay(capture, frames: Array(capture.frames.prefix(initIndex + 1)), reads: false)
    #expect(replay.rejections.count == 1, "\(replay.rejections)")
    #expect(replay.rejections.first?.hasPrefix("frame \(initIndex + 1) unsafeInitialization/initializationToolsInvalid") == true,
            "\(replay.rejections)")
    #expect(replay.calls.isEmpty)
}

@Test("Claude Code 2.1.272: work and hiring together replay whole, with the exact allow rule and with a question first",
      arguments: ["a3-allow", "a2-ask"])
func cli2_1_272WorkAndHireTurnReplays(run: String) throws {
    let capture = try HireProbeCapture(run: run)
    #expect(capture.shape == "hire")
    let replay = try replay(capture)
    #expect(replay.rejections.isEmpty, "\(replay.rejections)")
    #expect(replay.completed)
    try expectOneAnswerEach(replay, capture)
    #expect(replay.calls.count == 1)
    #expect(replay.calls.allSatisfy { $0.isOwnCall })
    let questions = replay.events.compactMap { event -> ClaudeTextPermissionRequest? in
        if case .permissionRequested(let question) = event { return question }; return nil
    }
    // Without the allow rule the CLI asks first, about the admitted hire tool.
    #expect(questions.map(\.toolName) == (run == "a2-ask" ? [ClaudeTextHirePolicy.qualifiedToolName] : []))
    #expect(questions.allSatisfy { $0.admitted })
}

@Test("Claude Code 2.1.272: timeouts, a refused message, an empty answer and refusals replay whole; each call reaches the service and each cancellation is answered",
      arguments: [("a5-faults", 4), ("a10-refusals", 4)])
func cli2_1_272FaultsReplay(run: String, calls: Int) throws {
    let capture = try HireProbeCapture(run: run)
    let replay = try replay(capture)
    #expect(replay.rejections.isEmpty, "\(replay.rejections)")
    #expect(replay.completed)
    #expect(replay.calls.count == calls)
    #expect(Set(replay.calls.map(\.toolUseID)).count == calls, "each call its own tool use")
    #expect(replay.calls.allSatisfy { $0.isOwnCall })
    let cancellations = serverMessages(capture).filter { $0.message["method"] as? String == "notifications/cancelled" }
    #expect(cancellations.count == (run == "a5-faults" ? 2 : 0))
    for cancellation in cancellations {
        #expect(replay.answers.contains { (($0["response"] as? [String: Any])?["request_id"] as? String) == cancellation.requestID })
    }
}

/// Fixture a4-helper: the probe's helper definition listed the hire tool (the
/// app's never does), so a helper could call it. The call arrives parented
/// under the Agent call, and that is how the stream knows it is not the bot's
/// own: the service refuses such a call without making anyone.
@Test("Claude Code 2.1.272: a hire call a helper made underneath its Agent call replays whole and is never the bot's own call")
func cli2_1_272HelperHireCallIsNotTheBotsOwn() throws {
    let capture = try HireProbeCapture(run: "a4-helper")
    #expect(capture.shape == "hire")
    let replay = try replay(capture, allowsHelpers: true)
    #expect(replay.rejections.isEmpty, "\(replay.rejections)")
    #expect(replay.completed)
    try expectOneAnswerEach(replay, capture)
    let call = try #require(replay.calls.first)
    #expect(replay.calls.count == 1)
    #expect(!call.isOwnCall, "a helper's call, parented under the Agent call")
    // The helper asked first, as the helper it is.
    let questions = replay.events.compactMap { event -> ClaudeTextPermissionRequest? in
        if case .permissionRequested(let question) = event { return question }; return nil
    }
    #expect(questions.map(\.toolName) == [ClaudeTextHelperPolicy.toolName, ClaudeTextHirePolicy.qualifiedToolName])
}

/// The launch a bot with Gmail, Messages or Control this Mac and the hire switch
/// gets, captured live: the connector's server from the configuration file and
/// the app's hire server over the channel, in one init frame.
@Test("Claude Code 2.1.272: a connector beside the hire server replays whole; the connector's call asks first, the hire call goes straight to the host")
func cli2_1_272HireBesideAConnectorReplays() throws {
    let capture = try HireProbeCapture(run: "a14-hire-beside-connector")
    #expect(capture.shape == "hire-only" && capture.readsFolders)
    let connector = try #require(capture.connectorName)
    let echo = "mcp__\(connector)__echo"
    let replay = try replay(capture)
    #expect(replay.rejections.isEmpty, "\(replay.rejections)")
    #expect(replay.completed)
    try expectOneAnswerEach(replay, capture)
    let call = try #require(replay.calls.first)
    #expect(replay.calls.count == 1 && call.isOwnCall)
    // No rule allows a connector's tool, so the CLI asks; the hire tool is allowed by name and never asks.
    let questions = replay.events.compactMap { event -> ClaudeTextPermissionRequest? in
        if case .permissionRequested(let question) = event { return question }; return nil
    }
    #expect(questions.map(\.toolName) == [echo] && questions.allSatisfy(\.admitted))
    let uses = replay.events.compactMap { event -> ClaudeTextToolUse? in
        if case .toolUse(let use) = event { return use }; return nil
    }
    #expect(uses.map(\.toolName) == [echo, ClaudeTextHirePolicy.qualifiedToolName])
    let finished = replay.events.compactMap { event -> String? in
        if case .toolFinished(let id, let failed) = event, !failed { return id }; return nil
    }
    #expect(finished == uses.map(\.id))
}

@Test("Claude Code 2.1.272: the connector-and-hire wire is refused at its init frame on a turn launched without the connector")
func cli2_1_272HireBesideAConnectorWithoutTheConnectorIsRefused() throws {
    let capture = try HireProbeCapture(run: "a14-hire-beside-connector")
    let initIndex = try capture.index { $0["type"] as? String == "system" && $0["subtype"] as? String == "init" }
    let replay = try replay(capture, frames: Array(capture.frames.prefix(initIndex + 1)), connector: false)
    #expect(replay.rejections.count == 1, "\(replay.rejections)")
    #expect(replay.rejections.first?.hasPrefix("frame \(initIndex + 1) unsafeInitialization/initializationToolsInvalid") == true,
            "\(replay.rejections)")
}

@Test("Claude Code 2.1.272: the same hire wire on a turn without the grant is refused at the server's first message")
func cli2_1_272HireWireWithoutTheGrantIsRefused() throws {
    let capture = try HireProbeCapture(run: "a12-hire-only")
    let replay = try replay(capture, grantsHiring: false)
    let first = try #require(replay.rejections.first)
    #expect(first.hasPrefix("frame 1 invalidStream/unexpectedEvent"), "\(first)")
    #expect(!replay.completed)
    #expect(replay.calls.isEmpty)
}

@Test("Claude Code 2.1.272: an init frame naming another server beside the hire server, or missing the hire tool, is refused at that frame")
func cli2_1_272PlantedHireInitIsRefused() throws {
    let capture = try HireProbeCapture(run: "a12-hire-only")
    let initIndex = try capture.index { $0["type"] as? String == "system" && $0["subtype"] as? String == "init" }
    let extraServer = try capture.editing(initIndex) {
        $0["mcp_servers"] = [["name": "openbots", "status": "connected"], ["name": "planted", "status": "connected"]]
    }
    let extra = try replay(capture, frames: extraServer)
    #expect(extra.rejections.first?.hasPrefix("frame \(initIndex + 1) unsafeInitialization/initializationMCPInvalid") == true,
            "\(extra.rejections)")
    let failedServer = try capture.editing(initIndex) { $0["mcp_servers"] = [["name": "openbots", "status": "failed"]] }
    #expect(try replay(capture, frames: failedServer).rejections.first?.hasPrefix("frame \(initIndex + 1) unsafeInitialization/initializationMCPInvalid") == true)
    let missingTool = try capture.editing(initIndex) { $0["tools"] = ["AskUserQuestion"] }
    #expect(try replay(capture, frames: missingTool).rejections.first?.hasPrefix("frame \(initIndex + 1) unsafeInitialization/initializationToolsInvalid") == true)
    let plantedTool = try capture.editing(initIndex) {
        $0["tools"] = ["AskUserQuestion", "mcp__openbots__hire_teammate", "mcp__openbots__fire_teammate"]
    }
    #expect(try replay(capture, frames: plantedTool).rejections.first?.hasPrefix("frame \(initIndex + 1) unsafeInitialization/initializationToolsInvalid") == true)
}
