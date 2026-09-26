import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsRuntime

// A connector that hands back a picture — Control this Mac's `see` and `image`,
// the browser's screenshot. Probed on Claude Code 2.1.272 with a stand-in
// server returning a 600×500 PNG: the CLI re-encodes the
// picture as a JPEG (363,656 base64 bytes here) and writes it TWICE in the one
// user frame that finishes the call, once in the tool result's content and
// once in `tool_use_result`, so that single line was 727,896 bytes. The
// stream's text-sized bounds (a 512 KiB line, 2 MiB a turn) ended the reply at
// the first real screenshot.

private let pictureServer = "openbots_" + String(repeating: "91c7", count: 16)
/// The probe's own measurement: the re-encoded picture's base64 length.
private let probedPictureBase64Bytes = 363_656

private func pictureRequest(_ role: ClaudeTextConnectorRole) throws -> ClaudeTextOnlyRequest {
    let server = try ClaudeTextConnectorServer(name: pictureServer, role: role,
        program: .installedTool(URL(fileURLWithPath: "/private/tmp/openbots-picture-fixture")), options: [], environment: [:])
    return try textOnlyTestRequest(connectorAccess: try ClaudeTextConnectorAccess(servers: [server]))
}

/// One call in the 2.1.272 wire order, finished by a user frame carrying the
/// picture the way the CLI writes it: in the result's content and again in
/// `tool_use_result`.
private func pictureCallFrames(_ request: ClaudeTextOnlyRequest, index: Int, base64Bytes: Int) throws -> [Data] {
    let id = "toolu_picture_\(index)", tool = "mcp__\(pictureServer)__see"
    let session = request.sessionID.uuidString
    let picture: [String: Any] = ["type": "image",
        "source": ["type": "base64", "media_type": "image/jpeg",
                   "data": "/9j/" + String(repeating: "A", count: base64Bytes - 4)]]
    return [
        try textOnlyTestLine(["type": "stream_event", "session_id": session,
            "event": ["type": "content_block_start", "index": 1,
                      "content_block": ["type": "tool_use", "id": id, "name": tool, "input": [:]]]]),
        try textOnlyTestLine(["type": "assistant", "session_id": session,
            "message": ["role": "assistant", "model": request.expectedResolvedModel,
                        "content": [["type": "tool_use", "id": id, "name": tool, "input": ["app": "Mail"]]]]]),
        try textOnlyTestLine(["type": "control_request", "request_id": "req-\(index)", "session_id": session,
            "request": ["subtype": "can_use_tool", "tool_name": tool, "tool_use_id": id, "input": ["app": "Mail"]]]),
        try textOnlyTestLine(["type": "control_response",
            "response": ["subtype": "success", "request_id": "req-\(index)", "response": ["behavior": "allow"]]]),
        try textOnlyTestLine(["type": "user", "uuid": UUID().uuidString, "session_id": session, "parent_tool_use_id": NSNull(),
            "timestamp": "2026-09-15T18:00:00.000Z",
            "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id,
                                                     "content": [picture, ["type": "text", "text": "Mail, 1 window"]]]]],
            "tool_use_result": [picture, ["type": "text", "text": "Mail, 1 window"]]]),
    ]
}

private struct PictureStop { var call: Int; var frame: Int; var rejection: ClaudeTextOnlyRejection }

private func feedPictures(_ request: ClaudeTextOnlyRequest, calls: Int, base64Bytes: Int = probedPictureBase64Bytes) throws
    -> (stream: ClaudeTextOnlyStream, stop: PictureStop?) {
    var stream = ClaudeTextOnlyStream(request: request, control: ClaudeTextTurnControl())
    stream.expectControlInitialization(requestID: "init-1")
    try stream.consume(try textOnlyTestLine(["type": "control_response",
        "response": ["subtype": "success", "request_id": "init-1", "response": [String: Any]()]])) { _ in }
    try stream.consume(try textOnlyTestInit(request, override: [
        "tools": request.grantedToolNames + request.appServerToolNames + ["mcp__\(pictureServer)__see"],
        "mcp_servers": [["name": pictureServer, "status": "connected"]] + appServerEntries(request), "permissionMode": "default"])) { _ in }
    try stream.consume(try textOnlyTestReplay(request)) { _ in }
    for call in 1...calls {
        for (frame, data) in try pictureCallFrames(request, index: call, base64Bytes: base64Bytes).enumerated() {
            do { try stream.consume(data) { _ in } } catch let rejection as ClaudeTextOnlyRejection {
                return (stream, PictureStop(call: call, frame: frame, rejection: rejection))
            }
        }
    }
    return (stream, nil)
}

@Test("A Control this Mac look at the screen, echoed twice in one frame as 2.1.272 writes it, does not end the reply",
      arguments: [ClaudeTextConnectorRole.macControl, .browser])
func aScreenshotFitsAPictureReply(role: ClaudeTextConnectorRole) throws {
    let (stream, stop) = try feedPictures(try pictureRequest(role), calls: 1)
    #expect(stop == nil, "\(String(describing: stop))")
    #expect(stream.grantedToolResultCount == 1)
}

@Test("A long look at the screen fits: every call of a Control this Mac reply may hand back a screenshot")
func everyCallOfAMacControlReplyMayHandBackAScreenshot() throws {
    let calls = ClaudeTextOnlyStream.maximumGrantedToolUses + ClaudeTextOnlyStream.maximumMacControlCalls
    let (stream, stop) = try feedPictures(try pictureRequest(.macControl), calls: calls)
    #expect(stop == nil, "\(String(describing: stop))")
    #expect(stream.grantedToolResultCount == calls)
}

@Test("A picture turn is still bounded: a frame bigger than two of the largest pictures the CLI sends ends the reply")
func aPictureTurnIsStillBounded() throws {
    let tooLarge = ClaudeTextOnlyStream.maximumPictureLineBytes / 2 + 1
    let (_, stop) = try feedPictures(try pictureRequest(.macControl), calls: 1, base64Bytes: tooLarge)
    let stopped = try #require(stop)
    #expect(stopped.frame == 4)
    #expect(stopped.rejection == ClaudeTextOnlyRejection(failure: .outputLimitExceeded, code: .outputLimitExceeded))
}

@Test("A connector turn that hands back no pictures keeps the text-sized line", arguments: [ClaudeTextConnectorRole.appleMessages, .googleGmailReadDraft])
func aTurnWithoutAPictureConnectorKeepsItsBounds(role: ClaudeTextConnectorRole) throws {
    let (_, stop) = try feedPictures(try pictureRequest(role), calls: 1)
    let stopped = try #require(stop)
    #expect(stopped.frame == 4)
    #expect(stopped.rejection == ClaudeTextOnlyRejection(failure: .outputLimitExceeded, code: .outputLimitExceeded))
}

/// Feeds one picture frame the way `ClaudeTextOnlyProcess.drain` reads the pipe:
/// 4,096 bytes at a time. Returns the seconds `consume` spent on that frame.
private func secondsToReadPictureFrame(base64Bytes: Int) throws -> Double {
    let request = try pictureRequest(.macControl)
    var stream = ClaudeTextOnlyStream(request: request, control: ClaudeTextTurnControl())
    stream.expectControlInitialization(requestID: "init-1")
    try stream.consume(try textOnlyTestLine(["type": "control_response",
        "response": ["subtype": "success", "request_id": "init-1", "response": [String: Any]()]])) { _ in }
    try stream.consume(try textOnlyTestInit(request, override: [
        "tools": request.grantedToolNames + request.appServerToolNames + ["mcp__\(pictureServer)__see"],
        "mcp_servers": [["name": pictureServer, "status": "connected"]] + appServerEntries(request), "permissionMode": "default"])) { _ in }
    try stream.consume(try textOnlyTestReplay(request)) { _ in }
    let frames = try pictureCallFrames(request, index: 1, base64Bytes: base64Bytes)
    for frame in frames.dropLast() { try stream.consume(frame) { _ in } }
    let picture = try #require(frames.last)
    let started = ContinuousClock.now
    var offset = 0
    while offset < picture.count {
        let end = min(offset + 4_096, picture.count)
        try stream.consume(picture.subdata(in: offset..<end)) { _ in }
        offset = end
    }
    let elapsed = ContinuousClock.now - started
    #expect(stream.grantedToolResultCount == 1)
    return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
}

/// A stream that searches its whole buffer for a newline on every read makes a
/// frame's cost grow with the square of its size (a 256 KB frame read in 0.05 s,
/// 512 KB in 0.18 s, 1 MB in 0.69 s), and the largest picture the CLI sends
/// would hold the pipe for over a minute.
@Test("A picture frame fed four kilobytes at a time is read in time that grows with its size, not its square")
func aPictureFrameIsReadInLinearTime() throws {
    let seconds = try secondsToReadPictureFrame(base64Bytes: 1_048_576)
    #expect(seconds < 1.0, "a 2 MB frame took \(seconds) s")
}

@Test("A picture turn's output bound holds the largest picture frame for every call the turn may make")
func aPictureTurnsOutputHoldsAPictureForEveryCall() {
    let calls = ClaudeTextOnlyStream.maximumGrantedToolUses + ClaudeTextOnlyStream.maximumMacControlCalls
    #expect(ClaudeTextOnlyStream.maximumPictureOutputBytes >= calls * ClaudeTextOnlyStream.maximumPictureLineBytes)
}

/// A turn runs on a thread of
/// its own with no autorelease pool (`NativeClaudeTextOnlyRunner` detaches one
/// per turn), so whatever Foundation autoreleased while parsing a picture line
/// stayed alive until the turn ended; and a picture line read 4,096 bytes at a
/// time doubled its buffer on the way up to ten megabytes, and the allocator
/// kept every block it outgrew. Measured through the real stream on such a
/// thread: 128 of the largest screenshot calls held 666 MB alive, and 64 left
/// the process 600 MB larger. Memory is measured for the whole process, so this
/// suite is serialized and is best run apart from other suites.
@Suite("A long picture turn's memory", .serialized)
struct PictureTurnMemoryTests {
    private final class Outcome: @unchecked Sendable {
        var liveGrowth = 0, footprintGrowth = 0, failure: String?
    }

    private static func liveBytes() -> Int {
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        return Int(statistics.size_in_use)
    }

    private static func footprintBytes() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    /// The largest picture calls through the real stream on a new thread without
    /// a pool, read as the process reads the pipe, with memory sampled after
    /// `baseline` calls and again after the last, while the thread is still alive.
    private static func measure(calls: Int, baseline: Int) throws -> Outcome {
        let request = try pictureRequest(.macControl)
        let outcome = Outcome()
        let finished = DispatchSemaphore(value: 0)
        let turn = Thread {
            defer { finished.signal() }
            do {
                var stream = ClaudeTextOnlyStream(request: request, control: ClaudeTextTurnControl())
                stream.expectControlInitialization(requestID: "init-1")
                // Only the stream's own work may leave anything behind on this thread.
                let opening = try autoreleasepool {
                    [try textOnlyTestLine(["type": "control_response",
                        "response": ["subtype": "success", "request_id": "init-1", "response": [String: Any]()]]),
                     try textOnlyTestInit(request, override: [
                        "tools": request.grantedToolNames + request.appServerToolNames + ["mcp__\(pictureServer)__see"],
                        "mcp_servers": [["name": pictureServer, "status": "connected"]] + appServerEntries(request), "permissionMode": "default"]),
                     try textOnlyTestReplay(request)]
                }
                for line in opening { try stream.consume(line) { _ in } }
                var live = 0, footprint = 0
                for call in 1...calls {
                    let frames = try autoreleasepool {
                        try pictureCallFrames(request, index: call, base64Bytes: 5_242_880)
                    }
                    for frame in frames {
                        var offset = 0
                        while offset < frame.count {
                            let end = min(offset + 4_096, frame.count)
                            try stream.consume(frame.subdata(in: offset..<end)) { _ in }
                            offset = end
                        }
                    }
                    if call == baseline { live = liveBytes(); footprint = footprintBytes() }
                }
                guard stream.grantedToolResultCount == calls else {
                    outcome.failure = "the stream counted \(stream.grantedToolResultCount) results"; return
                }
                outcome.liveGrowth = liveBytes() - live
                outcome.footprintGrowth = footprintBytes() - footprint
            } catch {
                outcome.failure = "\(error)"
            }
        }
        turn.start()
        finished.wait()
        return outcome
    }

    @Test("A long picture turn on its own thread keeps no parsed screenshot alive until the turn ends")
    func parsedPicturesAreNotKeptUntilTheTurnEnds() throws {
        let outcome = try Self.measure(calls: 32, baseline: 4)
        #expect(outcome.failure == nil, "\(outcome.failure ?? "")")
        #expect(outcome.liveGrowth < 64 * 1_048_576, "28 calls kept \(outcome.liveGrowth / 1_048_576) MB alive")
    }

    @Test("A long picture turn does not leave the allocator holding a buffer for every screenshot")
    func outgrownLineBuffersAreNotLeftWithTheAllocator() throws {
        let outcome = try Self.measure(calls: 32, baseline: 4)
        #expect(outcome.failure == nil, "\(outcome.failure ?? "")")
        #expect(outcome.footprintGrowth < 96 * 1_048_576, "28 calls grew the process by \(outcome.footprintGrowth / 1_048_576) MB")
    }
}
