import Foundation
import Testing
@testable import OpenBotsRuntime

// A reply with
// Control this Mac gets sixty-four rounds, and when they run out a card offers
// sixty-four more. The wire of a renewal, replayed through the parser
// (Fixtures/claude-cli-2.1.281/rounds-renewal, see its README): a
// work turn capped at four rounds, then one more message on the same stdin. The
// app never renews a work turn; the request flag is set here by hand, since
// Control this Mac cannot be driven in a probe and the renewal does not depend
// on the shape.

private let macServerName = "openbots_" + String(repeating: "5ac0", count: 16)

private struct RenewalCapture {
    let sessionID: UUID
    let messageID: UUID
    let controlID: String
    let prompt: String
    let model: String
    let cwd: String
    /// What the host wrote as the second message: its id and its words.
    let renewalID: UUID
    let renewalText: String
    let frames: [Data]

    init() throws {
        let root = try #require(Bundle.module.url(forResource: "claude-cli-2.1.281", withExtension: nil, subdirectory: "Fixtures"))
        let folder = root.appendingPathComponent("rounds-renewal")
        let argv = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("argv.json"))) as? [String: Any])
        let meta = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("meta.json"))) as? [String: Any])
        sessionID = try #require((argv["session_id"] as? String).flatMap(UUID.init(uuidString:)))
        messageID = try #require((argv["message_id"] as? String).flatMap(UUID.init(uuidString:)))
        controlID = try #require(argv["control_id"] as? String)
        cwd = try #require(argv["cwd"] as? String)
        prompt = try #require(meta["prompt"] as? String)
        model = try #require(meta["model"] as? String)
        var frames: [Data] = []
        var userMessages: [[String: Any]] = []
        for line in try String(contentsOf: folder.appendingPathComponent("wire.jsonl"), encoding: .utf8).split(separator: "\n") {
            let record = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            guard var frame = record["frame"] as? [String: Any] else { continue }
            if record["dir"] as? String == "host" {
                if frame["type"] as? String == "user" { userMessages.append(frame) }
                continue
            }
            if frame["type"] as? String == "system", frame["subtype"] as? String == "init",
               frame["apiKeySource"] as? String == "redacted" { frame["apiKeySource"] = "none" }
            var data = try JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys])
            data.append(0x0a)
            frames.append(data)
        }
        #expect(userMessages.count == 2)
        let second = try #require(userMessages.last)
        renewalID = try #require((second["uuid"] as? String).flatMap(UUID.init(uuidString:)))
        let content = try #require((second["message"] as? [String: Any])?["content"] as? [[String: Any]])
        renewalText = try #require(content.first?["text"] as? String)
        self.frames = frames
    }

    /// The probe's shape as the app would build it, renewing by card.
    func request() throws -> ClaudeTextOnlyRequest {
        // The scrubber wrote the bot's folder as `$RUN/botfolder`; the stream
        // never reads it, so any absolute folder stands in.
        #expect(cwd == "$RUN/botfolder")
        let work = try ClaudeTextWorkAccess(workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/rounds-renewal.noindex/botfolder"),
                                            protectedPaths: [])
        var request = try textOnlyTestRequest(allowedTools: [.webSearch, .webFetch], workAccess: work)
        request = try ClaudeTextOnlyRequest(target: request.target, runID: UUID(), sessionID: sessionID,
            messageID: messageID, text: prompt, systemPrompt: "probe", model: model,
            allowedTools: [.webSearch, .webFetch], workAccess: work)
        request.renewsRoundsByCard = true
        return request
    }

    func index(of type: String, subtype: String? = nil, after start: Int = 0) throws -> Int {
        try #require(frames.indices.first { index in
            guard index >= start, let root = try? JSONSerialization.jsonObject(with: frames[index]) as? [String: Any] else { return false }
            return root["type"] as? String == type && (subtype == nil || root["subtype"] as? String == subtype)
        })
    }
}

private struct RenewalReplay {
    var stream: ClaudeTextOnlyStream
    var events: [ClaudeTextOnlyEvent] = []
    var rejection: (index: Int, rejection: ClaudeTextOnlyRejection)?
}

/// Feeds the frames, allowing every question, and at `.roundsRanOut` calls
/// `renew` with the stream, as the transport does with the user's answer.
private func replay(_ capture: RenewalCapture, frames: [Data]? = nil, request: ClaudeTextOnlyRequest? = nil,
                    renew: (inout ClaudeTextOnlyStream) -> Void) throws -> RenewalReplay {
    let control = ClaudeTextTurnControl()
    var stream = ClaudeTextOnlyStream(request: try request ?? capture.request(), control: control)
    stream.expectControlInitialization(requestID: capture.controlID)
    var events: [ClaudeTextOnlyEvent] = []
    for (index, frame) in (frames ?? capture.frames).enumerated() {
        var ranOut = false
        do {
            try stream.consume(frame) { event in
                events.append(event)
                if case .roundsRanOut = event { ranOut = true }
                if case .permissionRequested(let question) = event {
                    control.register(question)
                    control.respond(requestID: question.requestID, allow: true)
                }
            }
        } catch let rejection as ClaudeTextOnlyRejection {
            return RenewalReplay(stream: stream, events: events, rejection: (index, rejection))
        }
        if ranOut { renew(&stream) }
    }
    return RenewalReplay(stream: stream, events: events, rejection: nil)
}

private func count(_ events: [ClaudeTextOnlyEvent], _ match: (ClaudeTextOnlyEvent) -> Bool) -> Int {
    events.filter(match).count
}

@Test("A Control this Mac turn launches with sixty-four rounds and renews by card; every other turn keeps its cap and does not")
func macControlTurnsGetSixtyFourRounds() throws {
    let server = try ClaudeTextConnectorServer(name: macServerName, role: .macControl,
        program: .installedTool(URL(fileURLWithPath: "/private/tmp/openbots-peekaboo-fixture")), options: [], environment: [:])
    let mac = try textOnlyTestRequest(connectorAccess: try ClaudeTextConnectorAccess(servers: [server]))
    let macAndWeb = try textOnlyTestRequest(allowedTools: [.webSearch], connectorAccess: try ClaudeTextConnectorAccess(servers: [server]))
    let browser = try textOnlyTestRequest(connectorAccess: try ClaudeTextConnectorAccess(servers: [connectorServerFixture()]))
    let web = try textOnlyTestRequest(allowedTools: [.webSearch, .webFetch])
    let plain = try textOnlyTestRequest()
    func maxTurns(_ request: ClaudeTextOnlyRequest) -> String? {
        let arguments = ClaudeTextOnlyCommandBuilder.arguments(for: request)
        return arguments.firstIndex(of: "--max-turns").map { arguments[$0 + 1] }
    }
    #expect(maxTurns(mac) == "64" && maxTurns(macAndWeb) == "64")
    #expect(maxTurns(browser) == "16" && maxTurns(web) == "16")
    #expect(maxTurns(plain) == "1")
    #expect(mac.renewsRoundsByCard && macAndWeb.renewsRoundsByCard)
    #expect(!browser.renewsRoundsByCard && !web.renewsRoundsByCard && !plain.renewsRoundsByCard)
    // `--max-turns 64` leaves sixty-three rounds of tools, as the prompt
    // says; the message the bot reads says the same.
    #expect(ClaudeTextRoundsRenewal.message == "You have 63 more rounds of tool calls on this Mac. Carry on where you left off.")
    // The calls a window of sixty-four rounds may make: twice the rounds.
    #expect(ClaudeTextOnlyStream.maximumMacControlCalls == 2 * ClaudeTextOnlyCommandBuilder.maximumMacControlTurns)
}

@Test("Claude Code 2.1.281: a renewed turn replays whole; the rounds run out, the renewal is accepted, and the reply finishes with the first command's output")
func cli2_1_281RenewalReplays() throws {
    let capture = try RenewalCapture()
    var accepted = false
    let replayed = try replay(capture) { stream in
        accepted = stream.acceptRenewal(messageID: capture.renewalID, text: capture.renewalText)
    }
    #expect(replayed.rejection == nil, "\(String(describing: replayed.rejection))")
    #expect(accepted)
    #expect(replayed.stream.renewalCount == 1)
    #expect(replayed.stream.hasCompleted && !replayed.stream.isAwaitingRenewal)
    guard case .success(let reply) = replayed.stream.finish(exitCode: 0) else { Issue.record("the renewed turn did not finish"); return }
    #expect(reply.text.contains("0617b958849bf135"), "\(reply.text)")
    // One of each for the host, whatever the CLI said twice: it holds one
    // initialization and one acknowledgement a turn.
    #expect(count(replayed.events) { if case .initialized = $0 { true } else { false } } == 1)
    #expect(count(replayed.events) { if case .inputAcknowledged = $0 { true } else { false } } == 1)
    #expect(count(replayed.events) { $0 == .roundsRanOut } == 1)
    // All six commands ran, four before the cap and two after it.
    let commands = replayed.events.compactMap { event -> String? in
        guard case .toolUse(let use) = event,
              let input = try? JSONSerialization.jsonObject(with: use.inputJSON) as? [String: Any] else { return nil }
        return input["command"] as? String
    }
    #expect(commands.count == 6 && commands.last == "echo six", "\(commands)")
}

@Test("Without the user's approval nothing of a second message passes: its lifecycle, and any output, are refused as today")
func cli2_1_281SecondMessageWithoutApprovalIsRefused() throws {
    let capture = try RenewalCapture()
    // The rounds ran out and nobody answered: the next frame about the new
    // message is refused, while the first message's own completion passes.
    let unanswered = try replay(capture) { _ in }
    let rejected = try #require(unanswered.rejection)
    #expect(rejected.rejection == ClaudeTextOnlyRejection(failure: .invalidStream, code: .invalidCommandLifecycle))
    let root = try #require(JSONSerialization.jsonObject(with: capture.frames[rejected.index]) as? [String: Any])
    #expect(root["command_uuid"] as? String == capture.renewalID.uuidString.lowercased(), "\(root)")
    #expect(unanswered.stream.isAwaitingRenewal)
    // A child that exits while the card waits ends at its round cap.
    #expect(unanswered.stream.finish(exitCode: 0) == .failed(.turnLimitReached))

    // An approval for another id: the CLI's frames for its own are refused the same way.
    let other = try replay(capture) { stream in _ = stream.acceptRenewal(messageID: UUID(), text: capture.renewalText) }
    #expect(other.rejection?.rejection == ClaudeTextOnlyRejection(failure: .invalidStream, code: .invalidCommandLifecycle))

    // A turn that does not renew ends at the capped result, exactly as before.
    var plain = try capture.request()
    plain.renewsRoundsByCard = false
    let unrenewed = try replay(capture, request: plain) { _ in Issue.record("a turn that does not renew ran out of rounds") }
    #expect(unrenewed.rejection?.rejection == ClaudeTextOnlyRejection(failure: .turnLimitReached, code: .turnLimitReached))
    let cappedIndex = try capture.index(of: "result")
    #expect(unrenewed.rejection?.index == cappedIndex)

    // While the card waits, model output is refused as output after a result is.
    let stray = try textOnlyTestDelta(try capture.request(), text: "sneaking on")
    let early = try replay(capture, frames: Array(capture.frames[...cappedIndex]) + [stray]) { _ in }
    #expect(early.rejection?.rejection == ClaudeTextOnlyRejection(failure: .invalidStream, code: .eventAfterResult))
    // And a renewal is accepted once, only while one waits.
    var fresh = ClaudeTextOnlyStream(request: try capture.request(), control: ClaudeTextTurnControl())
    let acceptedWithoutWaiting = fresh.acceptRenewal(messageID: UUID())
    #expect(!acceptedWithoutWaiting)
}

@Test("An approved renewal still admits one init and one replay of its own, in the order the wire showed them")
func cli2_1_281RenewalAdmitsOneOfEach() throws {
    let capture = try RenewalCapture()
    let capped = try capture.index(of: "result")
    let secondInit = try capture.index(of: "system", subtype: "init", after: capped)
    let secondReplay = try capture.index(of: "user", after: secondInit)
    func edited(_ edit: (inout [Data]) -> Void) -> [Data] { var frames = capture.frames; edit(&frames); return frames }
    func renewing(_ frames: [Data]) throws -> RenewalReplay {
        try replay(capture, frames: frames) { stream in
            _ = stream.acceptRenewal(messageID: capture.renewalID, text: capture.renewalText)
        }
    }
    // A third init.
    let twoInits = try renewing(edited { $0.insert($0[secondInit], at: secondReplay + 1) })
    #expect(twoInits.rejection?.rejection == ClaudeTextOnlyRejection(failure: .unsafeInitialization, code: .duplicateInitialization))
    // The renewal's replay twice.
    let twoReplays = try renewing(edited { $0.insert($0[secondReplay], at: secondReplay + 1) })
    #expect(twoReplays.rejection?.rejection == ClaudeTextOnlyRejection(failure: .invalidStream, code: .replayDuplicate))
    // The replay before its init.
    let swapped = try renewing(edited { $0.swapAt(secondInit, secondReplay) })
    #expect(swapped.rejection?.rejection == ClaudeTextOnlyRejection(failure: .invalidStream, code: .replayMessageMismatch))
    // The second init on another model.
    let otherModel = try renewing(edited { frames in
        var root = (try? JSONSerialization.jsonObject(with: frames[secondInit]) as? [String: Any]) ?? [:]
        root["model"] = "claude-opus-5"
        var data = (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])) ?? Data()
        data.append(0x0a)
        frames[secondInit] = data
    })
    #expect(otherModel.rejection?.rejection == ClaudeTextOnlyRejection(failure: .unsafeInitialization, code: .initializationModelInvalid))
    // Model output of the renewed window that names the first message.
    let tagged = try #require(capture.frames.indices.first { index in
        index > secondReplay && String(decoding: capture.frames[index], as: UTF8.self).contains("\"user_message_uuid\"")
    })
    let misnamed = try renewing(edited { frames in
        var root = (try? JSONSerialization.jsonObject(with: frames[tagged]) as? [String: Any]) ?? [:]
        root["user_message_uuid"] = capture.messageID.uuidString.lowercased()
        var data = (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])) ?? Data()
        data.append(0x0a)
        frames[tagged] = data
    })
    #expect(misnamed.rejection?.rejection == ClaudeTextOnlyRejection(failure: .invalidStream, code: .responseMismatch))
    #expect(misnamed.rejection?.index == tagged)
    // Words other than the ones written.
    let otherWords = try replay(capture) { stream in
        _ = stream.acceptRenewal(messageID: capture.renewalID, text: ClaudeTextRoundsRenewal.message)
    }
    #expect(otherWords.rejection?.rejection == ClaudeTextOnlyRejection(failure: .invalidStream, code: .replayTextMismatch))
    // A second result after the success.
    let last = try capture.index(of: "result", after: capped + 1)
    let twoResults = try renewing(edited { $0.insert($0[last], at: last + 1) })
    #expect(twoResults.rejection?.rejection == ClaudeTextOnlyRejection(failure: .invalidStream, code: .eventAfterResult))
}

// MARK: The transport

private func renewalEmit(_ data: Data) throws -> String {
    let text = try #require(String(data: data, encoding: .utf8))
    return "/bin/cat <<'OPENBOTS_SYNTHETIC_EVENT'\n" + text + "OPENBOTS_SYNTHETIC_EVENT"
}

private actor RenewalEvents {
    private var values: [ClaudeTextOnlyEvent] = []
    func append(_ event: ClaudeTextOnlyEvent) { values.append(event) }
    func snapshot() -> [ClaudeTextOnlyEvent] { values }
}

/// A synthetic child on the work shape that renews: the handshake, the message,
/// "Working." and the capped result; then, when the host writes one more line,
/// the renewal's lifecycle, init and replay (the line itself echoed back), "Done."
/// and a success; and a line after that fails the child. It can pause before
/// the cap, for the process tests of the ceiling (ClaudeTextOnlyProcessTests).
func roundsRenewalChild(_ template: ClaudeTextOnlyRequest, endsAtTheCap: Bool = false,
                        pausesBeforeTheCap seconds: Int = 0) throws -> String {
    let initFrame = try textOnlyTestInit(template, override: ["tools": template.grantedToolNames, "permissionMode": "default"])
    let capped = try textOnlyTestResult(template, override: ["subtype": "error_max_turns", "is_error": true,
                                                              "user_message_uuid": template.messageID.uuidString.lowercased()])
    var body = """
    IFS= read -r handshake
    request_id=$(printf '%s' "$handshake" | /usr/bin/sed -n 's/.*"request_id":"\\([^"]*\\)".*/\\1/p')
    printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{}}}\\n' "$request_id"
    IFS= read -r line
    \(try renewalEmit(initFrame))
    printf '{"isReplay":true,"parent_tool_use_id":null,%s\\n' "${line#?}"
    \(try renewalEmit(textOnlyTestDelta(template, text: "Working. ")))
    \(seconds > 0 ? "/bin/sleep \(seconds)" : "")
    \(try renewalEmit(capped))
    """
    if endsAtTheCap { return body + "\nexit 0" }
    body += """

    IFS= read -r renewal || exit 45
    printf '%s\\n' "$renewal" > renewal-observed
    renewal_id=$(printf '%s' "$renewal" | /usr/bin/sed -n 's/.*"uuid":"\\([^"]*\\)".*/\\1/p')
    session='\(template.sessionID.uuidString.lowercased())'
    printf '{"type":"command_lifecycle","command_uuid":"%s","state":"queued","uuid":"%s","session_id":"%s"}\\n' "$renewal_id" "$(/usr/bin/uuidgen)" "$session"
    printf '{"type":"command_lifecycle","command_uuid":"%s","state":"started","uuid":"%s","session_id":"%s"}\\n' "$renewal_id" "$(/usr/bin/uuidgen)" "$session"
    \(try renewalEmit(initFrame))
    printf '{"isReplay":true,"parent_tool_use_id":null,%s\\n' "${renewal#?}"
    \(try renewalEmit(textOnlyTestDelta(template, text: "Done.")))
    \(try renewalEmit(textOnlyTestResult(template, override: ["result": "Done."])))
    if IFS= read -r extra; then exit 44; fi
    """
    return body
}

func roundsRenewalRequest(_ target: ClaudeConnectionTarget) throws -> ClaudeTextOnlyRequest {
    let desk = try ClaudeTextWorkAccess(workingDirectoryURL: target.workingDirectoryURL,
        additionalDirectoryURLs: [], protectedPaths: ["/private/tmp/protected-root.noindex"])
    var request = try textOnlyTestRequest(target: target, workAccess: desk)
    request.renewsRoundsByCard = true
    return request
}

@Test("The user's approval writes exactly one message on the open pipe, a new id in the same session with the fixed words, and the reply finishes")
func approvedRenewalWritesOneMessage() async throws {
    let template = try roundsRenewalRequest(try textOnlyTestRequest().target)
    let fixture = try ClaudeConnectionFixture(body: try roundsRenewalChild(template))
    defer { fixture.remove() }
    let request = try roundsRenewalRequest(fixture.target)
    let control = ClaudeTextTurnControl()
    let events = RenewalEvents()
    let result = await NativeClaudeTextOnlyRunner().run(request: request, control: control) { event in
        await events.append(event)
        if case .roundsRanOut = event {
            // The transport told the channel first, so the answer is never early.
            #expect(control.isAwaitingDecision)
            #expect(control.decideRoundsRenewal(renew: true))
            #expect(!control.decideRoundsRenewal(renew: true), "a double click renews once")
        }
    }
    #expect(result == .success(.init(sessionID: request.sessionID, actualModel: "claude-sonnet-5",
        text: "Working. Done.", confirmedActualModel: "claude-sonnet-5")))
    let observed = await events.snapshot()
    #expect(observed.filter { $0 == .roundsRanOut }.count == 1)
    #expect(observed.filter { $0 == .inputSubmitted(messageID: request.messageID) }.count == 1)
    #expect(!observed.contains { if case .diagnostic = $0 { true } else { false } })
    let written = try fixture.readWorkingFile("renewal-observed")
    let lines = written.split(separator: "\n")
    #expect(lines.count == 1)
    let frame = try #require(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
    let id = try #require((frame["uuid"] as? String).flatMap(UUID.init(uuidString:)))
    #expect(frame["type"] as? String == "user" && id != request.messageID)
    #expect(frame["session_id"] as? String == request.sessionID.uuidString.lowercased())
    let content = (frame["message"] as? [String: Any])?["content"] as? [[String: Any]]
    #expect(content?.count == 1 && content?.first?["text"] as? String == ClaudeTextRoundsRenewal.message)
}

@Test("A denied renewal ends the reply as the turn limit, keeping what it wrote, and writes nothing more")
func deniedRenewalEndsAtTheCap() async throws {
    let template = try roundsRenewalRequest(try textOnlyTestRequest().target)
    let fixture = try ClaudeConnectionFixture(body: try roundsRenewalChild(template))
    defer { fixture.remove() }
    let request = try roundsRenewalRequest(fixture.target)
    let control = ClaudeTextTurnControl()
    let events = RenewalEvents()
    let result = await NativeClaudeTextOnlyRunner().run(request: request, control: control) { event in
        await events.append(event)
        if case .roundsRanOut = event { control.decideRoundsRenewal(renew: false) }
    }
    #expect(result == .failed(.turnLimitReached))
    let observed = await events.snapshot()
    #expect(observed.contains(.textSnapshot("Working. ")))
    #expect(observed.last == .diagnostic(.turnLimitReached))
    #expect(!FileManager.default.fileExists(atPath: fixture.target.workingDirectoryURL.appendingPathComponent("renewal-observed").path))
}

@Test("A child that leaves while the renewal card waits ends at its round cap, not as a broken stream")
func childLeavingDuringTheCardEndsAtTheCap() async throws {
    let template = try roundsRenewalRequest(try textOnlyTestRequest().target)
    let fixture = try ClaudeConnectionFixture(body: try roundsRenewalChild(template, endsAtTheCap: true))
    defer { fixture.remove() }
    let request = try roundsRenewalRequest(fixture.target)
    let events = RenewalEvents()
    let result = await NativeClaudeTextOnlyRunner().run(request: request, control: ClaudeTextTurnControl()) { await events.append($0) }
    #expect(result == .failed(.turnLimitReached))
    #expect(await events.snapshot().last == .diagnostic(.turnLimitReached))
}

@Test("Stop while the renewal card waits ends the turn at once")
func stopWhileTheRenewalCardWaits() async throws {
    let template = try roundsRenewalRequest(try textOnlyTestRequest().target)
    let fixture = try ClaudeConnectionFixture(body: try roundsRenewalChild(template))
    defer { fixture.remove() }
    let request = try roundsRenewalRequest(fixture.target)
    let control = ClaudeTextTurnControl()
    let ranOut = RenewalEvents()
    let turn = Task {
        await NativeClaudeTextOnlyRunner().run(request: request, control: control) { event in
            if case .roundsRanOut = event { await ranOut.append(event) }
        }
    }
    for _ in 0..<1_000 where await ranOut.snapshot().isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await ranOut.snapshot() == [.roundsRanOut])
    turn.cancel()
    #expect(await turn.value == .cancelled)
    #expect(!FileManager.default.fileExists(atPath: fixture.target.workingDirectoryURL.appendingPathComponent("renewal-observed").path))
}
