import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsRuntime

// The setup tool's real wire, replayed through the parser
// and the host's answers. Each fixture is one probe run of Claude Code 2.1.280
// with the app's hire-only launch and the `openbots` server listing
// `set_up_self` (Tests/.../claude-cli-2.1.280/self-setup-probe/README.md):
//   s2-competitor-prices  the acceptance sentence: a question, then the call
//   s3-vague              "hi there": no call, one question back

private struct SetupProbeCapture {
    let sessionID: UUID
    let messageID: UUID
    let controlID: String
    let model: String
    /// What the user typed, as the probe sent it: the stream checks the CLI's echo against it.
    let text: String
    let frames: [Data]

    init(run: String) throws {
        let root = try #require(Bundle.module.url(forResource: "claude-cli-2.1.280", withExtension: nil, subdirectory: "Fixtures"))
        let folder = root.appendingPathComponent("self-setup-probe").appendingPathComponent(run)
        let argv = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("argv.json"))) as? [String: Any])
        let session = try #require(argv["session_id"] as? String), message = try #require(argv["message_id"] as? String)
        sessionID = try #require(UUID(uuidString: session))
        messageID = try #require(UUID(uuidString: message))
        controlID = try #require(argv["control_id"] as? String)
        let arguments = try #require(argv["argv"] as? [String])
        model = arguments[try #require(arguments.firstIndex(of: "--model")) + 1]
        text = run == "s3-vague" ? "hi there" : "you watch my competitors' prices and tell me when they drop"
        frames = try String(contentsOf: folder.appendingPathComponent("wire.jsonl"), encoding: .utf8)
            .split(separator: "\n").compactMap { line in
                let record = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                // A line with no frame is the probe's own note.
                guard let frame = record["frame"] as? [String: Any] else { return nil }
                var data = try JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys])
                data.append(0x0a)
                return data
            }
    }

    func request() throws -> ClaudeTextOnlyRequest {
        let target = try ClaudeConnectionTarget(
            executableURL: URL(fileURLWithPath: "/private/tmp/not-created-text.noindex/claude"),
            expectedExecutableSHA256: String(repeating: "a", count: 64),
            profileURL: URL(fileURLWithPath: "/private/tmp/not-created-text.noindex/profile"),
            workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/not-created-text.noindex/work"),
            temporaryDirectoryURL: URL(fileURLWithPath: "/private/tmp/not-created-text.noindex/temp"),
            homeDirectoryURL: URL(fileURLWithPath: "/private/tmp/not-created-text.noindex/home"))
        return try ClaudeTextOnlyRequest(target: target, runID: UUID(), sessionID: sessionID, messageID: messageID,
            text: text, systemPrompt: "probe", model: model,
            grantsSelfSetup: true)
    }
}

private struct SetupReplay {
    var events: [ClaudeTextOnlyEvent] = []
    var questions: [ClaudeTextPermissionRequest] = []
    var calls: [ClaudeTextSelfSetupCall] = []
    var rejections: [String] = []
    var answers: [[String: Any]] = []
    var text = ""
    var completed = false
}

private func replay(_ capture: SetupProbeCapture) throws -> SetupReplay {
    let request = try capture.request()
    let control = ClaudeTextTurnControl()
    var stream = ClaudeTextOnlyStream(request: request, control: control)
    stream.expectControlInitialization(requestID: capture.controlID)
    var result = SetupReplay()
    for (index, frame) in capture.frames.enumerated() {
        do {
            try stream.consume(frame) { event in
                result.events.append(event)
                if case .textSnapshot(let text) = event { result.text = text }
                if case .permissionRequested(let question) = event {
                    result.questions.append(question)
                    control.register(question)
                    control.respond(requestID: question.requestID, allow: question.admitted)
                }
                if case .selfSetupRequested(let call) = event {
                    result.calls.append(call)
                    control.answerSelfSetup(requestID: call.requestID, text: "You are set up as PriceWatch.", refused: false)
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

@Test("The acceptance sentence on 2.1.280: the tool listed, its permission question admitted, then the bot's own call, and the turn finishes")
func setupProbeAcceptance() throws {
    let capture = try SetupProbeCapture(run: "s2-competitor-prices")
    let replay = try replay(capture)
    #expect(replay.rejections.isEmpty, "\(replay.rejections)")
    #expect(replay.completed)
    // The tool list the host answered is exactly the setup tool.
    let listed = replay.answers.compactMap { answer -> [String]? in
        let reply = ((answer["response"] as? [String: Any])?["response"] as? [String: Any])?["mcp_response"] as? [String: Any]
        return ((reply?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
    }
    #expect(listed == [[ClaudeTextSelfSetupPolicy.toolName]])
    // The question comes first, for the setup tool, admitted: where the switch card waits.
    let question = try #require(replay.questions.first)
    #expect(replay.questions.count == 1 && question.admitted)
    #expect(question.toolName == ClaudeTextSelfSetupPolicy.qualifiedToolName)
    #expect(try BotSelfSetupRequest.parse(argumentsJSON: question.inputJSON).get().switches == [.webSearch, .webFetch])
    // Then the call, the bot's own, with the same arguments.
    let call = try #require(replay.calls.first)
    #expect(replay.calls.count == 1 && call.isOwnCall && call.toolUseID == question.toolUseID)
    let parsed = try BotSelfSetupRequest.parse(argumentsJSON: call.argumentsJSON).get()
    #expect(parsed.profileFields.handle == "PriceWatch" && parsed.switches == [.webSearch, .webFetch])
    #expect(replay.text.contains("PriceWatch"))
}

@Test("A vague first answer on 2.1.280: no call, one question back, and the turn finishes")
func setupProbeVague() throws {
    let replay = try replay(try SetupProbeCapture(run: "s3-vague"))
    #expect(replay.rejections.isEmpty, "\(replay.rejections)")
    #expect(replay.completed && replay.calls.isEmpty && replay.questions.isEmpty)
    #expect(replay.text.contains("?"))
}

@Test("A setup turn's launch: the connector-turn settings, the server named in the handshake, the tool never pre-approved")
func setupLaunchShape() throws {
    let request = try SetupProbeCapture(run: "s2-competitor-prices").request()
    #expect(request.requiresPermissionControl && request.carriesAppServer)
    let settings = ClaudeTextOnlyCommandBuilder.settingsJSON(for: request)
    #expect(!settings.contains("\"mcp__*\""), "the wildcard deny would shadow the server")
    #expect(!settings.contains(ClaudeTextSelfSetupPolicy.qualifiedToolName))
    #expect(!ClaudeTextOnlyCommandBuilder.preApprovedNames(for: request).contains(ClaudeTextSelfSetupPolicy.qualifiedToolName))
    let handshake = try JSONSerialization.jsonObject(with:
        ClaudeTextOnlyCommandBuilder.initializeControlRecord(id: "c", appServer: request.carriesAppServer)) as? [String: Any]
    #expect(((handshake?["request"] as? [String: Any])?["sdkMcpServers"] as? [String]) == ["openbots"])
}
