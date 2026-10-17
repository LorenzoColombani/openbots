import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsRuntime

private func longWorkAccess() throws -> ClaudeTextWorkAccess {
    try ClaudeTextWorkAccess(workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/work-budget.noindex"),
                             protectedPaths: [])
}

@Test("Work launches with sixty-four rounds; other grants keep their caps and only Mac control renews")
func workTurnLaunchBudgets() throws {
    let work = try longWorkAccess()
    let macServer = try ClaudeTextConnectorServer(name: "openbots_" + String(repeating: "b0d6", count: 16),
        role: .macControl, program: .installedTool(URL(fileURLWithPath: "/private/tmp/work-budget-helper")),
        options: [], environment: [:])
    let mac = try ClaudeTextConnectorAccess(servers: [macServer])
    let read = try ClaudeTextReadAccess(sharedDirectoryURL: URL(fileURLWithPath: "/private/tmp/shared-budget.noindex"),
                                       protectedPaths: [])
    let shapes: [(String, ClaudeTextOnlyRequest, String, Bool)] = [
        ("plain", try textOnlyTestRequest(), "1", false),
        ("read", try textOnlyTestRequest(readAccess: read), "16", false),
        ("web", try textOnlyTestRequest(allowedTools: [.webSearch, .webFetch]), "16", false),
        ("work", try textOnlyTestRequest(workAccess: work), "64", false),
        ("work and web", try textOnlyTestRequest(allowedTools: [.webSearch], workAccess: work), "64", false),
        ("Mac control", try textOnlyTestRequest(connectorAccess: mac), "64", true),
        ("work and Mac control", try textOnlyTestRequest(workAccess: work, connectorAccess: mac), "64", true),
    ]
    for (name, request, turns, renews) in shapes {
        let arguments = ClaudeTextOnlyCommandBuilder.arguments(for: request)
        let cap = try #require(arguments.firstIndex(of: "--max-turns").map { arguments[$0 + 1] })
        #expect(cap == turns, "\(name)")
        #expect(request.renewsRoundsByCard == renews, "\(name)")
        if request.grantsWork {
            let prompt = try #require(arguments.firstIndex(of: "--permission-prompt-tool").map { arguments[$0 + 1] })
            #expect(prompt == "stdio", "\(name)")
        }
    }
    #expect(ClaudeTextHelperPolicy.maximumTurns == 8)
    #expect(ClaudeTextHelperPolicy.maximumHelpers == 2)
}

/// The same correlated assistant / question / answer / result order used by
/// the captured work and Mac-control replays. Each assistant message is a
/// separate round. This exercises the parser; the CLI enforces --max-turns.
private func workBudgetRound(_ request: ClaudeTextOnlyRequest, index: Int, result: String, failed: Bool = false) throws -> [Data] {
    let toolID = "toolu_long_work_\(index)", questionID = "work-question-\(index)"
    let input = ["file_path": "/private/tmp/work-budget.noindex/part-\(index).txt"]
    return [
        try textOnlyTestLine(["type": "assistant", "session_id": request.sessionID.uuidString,
            "message": ["id": "msg_long_work_\(index)", "role": "assistant", "model": request.expectedResolvedModel,
                "content": [["type": "tool_use", "id": toolID, "name": "Read", "input": input]]]]),
        try textOnlyTestLine(["type": "control_request", "request_id": questionID,
            "request": ["subtype": "can_use_tool", "tool_name": "Read", "tool_use_id": toolID, "input": input]]),
        try textOnlyTestLine(["type": "control_response",
            "response": ["subtype": "success", "request_id": questionID, "response": ["behavior": "allow"]]]),
        try textOnlyTestLine(["type": "user", "session_id": request.sessionID.uuidString,
            "uuid": UUID().uuidString, "parent_tool_use_id": NSNull(),
            "message": ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": toolID, "content": result, "is_error": failed]]]]),
    ]
}

private func initializedWorkBudgetStream(_ request: ClaudeTextOnlyRequest) throws -> (ClaudeTextOnlyStream, Int) {
    var stream = ClaudeTextOnlyStream(request: request, control: ClaudeTextTurnControl())
    stream.expectControlInitialization(requestID: "init-budget")
    let frames = [
        try textOnlyTestLine(["type": "control_response",
            "response": ["subtype": "success", "request_id": "init-budget", "response": [String: Any]()]]),
        try textOnlyTestInit(request, override: ["tools": request.grantedToolNames, "permissionMode": "default"]),
        try textOnlyTestReplay(request),
    ]
    for frame in frames { try stream.consume(frame) { _ in } }
    return (stream, frames.reduce(0) { $0 + $1.count })
}

@Test("Seventeen Work tool rounds and over two MiB of correlated results finish across 4 KiB reads")
func longWorkStreamCompletes() throws {
    let request = try textOnlyTestRequest(workAccess: longWorkAccess())
    var (stream, byteCount) = try initializedWorkBudgetStream(request)
    var events: [ClaudeTextOnlyEvent] = []
    let output = String(repeating: "a", count: 192 * 1_024)
    for round in 1...17 {
        for frame in try workBudgetRound(request, index: round, result: output) {
            #expect(frame.count <= ClaudeTextOnlyStream.maximumLineBytes)
            byteCount += frame.count
            for start in stride(from: 0, to: frame.count, by: 4_096) {
                try stream.consume(frame.subdata(in: start..<min(start + 4_096, frame.count))) { events.append($0) }
            }
        }
    }
    #expect(byteCount > ClaudeTextOnlyStream.maximumOutputBytes)
    #expect(stream.grantedToolUseCount == 17 && stream.grantedToolResultCount == 17)
    #expect(stream.permissionRequestCount == 17)
    #expect(events.filter { if case .toolFinished = $0 { return true }; return false }.count == 17)
    for frame in [try textOnlyTestDelta(request, text: "Checked all seventeen files."),
                  try textOnlyTestResult(request, override: ["result": "Checked all seventeen files.", "num_turns": 18])] {
        byteCount += frame.count
        try stream.consume(frame) { events.append($0) }
    }
    let result = stream.finish(exitCode: 0)
    #expect(result == .success(.init(sessionID: request.sessionID,
        actualModel: request.expectedResolvedModel, text: "Checked all seventeen files.",
        confirmedActualModel: request.expectedResolvedModel)))
    let receipt = try #require(stream.completionReceipt(for: result))
    #expect(receipt.runID == request.runID && receipt.stdoutBytes == byteCount)
    #expect(receipt.toolCalls == 17 && receipt.toolResults == 17 && receipt.successfulToolResults == 17)
    #expect(receipt.resultTurns == 18 && receipt.renewals == 0)
}

@Test("Success receipts count distinct results and exclude failed calls, even when a result is repeated")
func completionReceiptCountsDistinctSuccessfulResults() throws {
    let request = try textOnlyTestRequest(workAccess: longWorkAccess())
    var (stream, _) = try initializedWorkBudgetStream(request)
    for index in 1...2 {
        let frames = try workBudgetRound(request, index: index, result: "Private tool content", failed: index == 2)
        for frame in frames { try stream.consume(frame) { _ in } }
        // The CLI may repeat a correlated result; diagnostics still count its ID once.
        try stream.consume(try #require(frames.last)) { _ in }
    }
    try stream.consume(textOnlyTestResult(request, override: ["num_turns": 3])) { _ in }
    let receipt = try #require(stream.completionReceipt(for: stream.finish(exitCode: 0)))
    #expect(receipt.toolCalls == 2 && receipt.toolResults == 2 && receipt.successfulToolResults == 1)
    #expect(receipt.resultTurns == 3)
}

@Test("Receipt turn counts accept only bounded integers from the final result")
func completionReceiptValidatesTurnCounts() throws {
    let request = try textOnlyTestRequest(workAccess: longWorkAccess())
    let values: [(Any?, Int?)] = [(nil, nil), (NSNull(), nil), (true, nil), ("18", nil), (0, nil),
        (-1, nil), (1.5, nil), (65, nil), (Double.greatestFiniteMagnitude, nil), (1, 1), (18, 18), (64, 64)]
    for (value, expected) in values {
        var (stream, _) = try initializedWorkBudgetStream(request)
        let fields: [String: Any] = value.map { ["num_turns": $0] } ?? [:]
        try stream.consume(textOnlyTestResult(request, override: fields)) { _ in }
        let receipt = try #require(stream.completionReceipt(for: stream.finish(exitCode: 0)))
        #expect(receipt.resultTurns == expected)
    }
}

@Test("Rejected, failed and incomplete streams provide no success receipt")
func completionReceiptRequiresAnAcceptedFinishedStream() throws {
    let request = try textOnlyTestRequest(workAccess: longWorkAccess())
    var (stream, _) = try initializedWorkBudgetStream(request)
    #expect(stream.completionReceipt(for: stream.finish(exitCode: 0)) == nil)
    try stream.consume(textOnlyTestResult(request, override: ["num_turns": 1])) { _ in }
    #expect(stream.completionReceipt(for: stream.finish(exitCode: 1)) == nil)
    #expect(stream.completionReceipt(for: .cancelled) == nil)
    #expect(throws: (any Error).self) { try stream.consume(Data("invalid\n".utf8)) { _ in } }
    #expect(stream.completionReceipt(for: stream.finish(exitCode: 0)) == nil)
}

@Test("Work's cumulative 64 MiB bound still refuses the next byte after a valid prefix")
func workCumulativeOutputRemainsBounded() throws {
    let request = try textOnlyTestRequest(workAccess: longWorkAccess())
    var (stream, byteCount) = try initializedWorkBudgetStream(request)
    let prefix = try textOnlyTestDelta(request, text: "Still working.")
    try stream.consume(prefix) { _ in }
    byteCount += prefix.count
    #expect(ClaudeTextOnlyStream.maximumWorkOutputBytes == 64 * 1_048_576)
    // Empty framing lines are valid and count toward the transport allowance.
    // Reuse a small chunk to reach the actual production boundary without a
    // giant allocation or hitting a separate call, reply or metadata limit.
    let framing = Data(repeating: 10, count: 65_536)
    while byteCount < ClaudeTextOnlyStream.maximumWorkOutputBytes {
        let count = min(framing.count, ClaudeTextOnlyStream.maximumWorkOutputBytes - byteCount)
        try stream.consume(Data(framing.prefix(count))) { _ in }
        byteCount += count
    }
    #expect(throws: ClaudeTextOnlyRejection(failure: .outputLimitExceeded, code: .outputLimitExceeded)) {
        try stream.consume(Data([10])) { _ in }
    }
    #expect(stream.textSoFar == "Still working.")
}

@Test("Plain text, web and read-only turns retain the two MiB cumulative allowance")
func nonWorkOutputBudgetsAreUnchanged() throws {
    let read = try ClaudeTextReadAccess(sharedDirectoryURL: URL(fileURLWithPath: "/private/tmp/shared-budget.noindex"),
                                       protectedPaths: [])
    let requests = [try textOnlyTestRequest(), try textOnlyTestRequest(allowedTools: [.webFetch]),
                    try textOnlyTestRequest(readAccess: read)]
    let framing = Data(repeating: 10, count: 65_536)
    for request in requests {
        var stream = ClaudeTextOnlyStream(request: request)
        for _ in 0..<32 { try stream.consume(framing) { _ in } }
        #expect(throws: ClaudeTextOnlyRejection(failure: .outputLimitExceeded, code: .outputLimitExceeded)) {
            try stream.consume(Data([10])) { _ in }
        }
    }
}

@Test("Work still refuses oversized lines, streamed replies and final answers")
func workLineAndReplyBoundsStaySmall() throws {
    let request = try textOnlyTestRequest(workAccess: longWorkAccess())
    var (line, _) = try initializedWorkBudgetStream(request)
    #expect(throws: ClaudeTextOnlyRejection(failure: .outputLimitExceeded, code: .outputLimitExceeded)) {
        try line.consume(Data(repeating: 120, count: 524_289)) { _ in }
    }
    var (reply, _) = try initializedWorkBudgetStream(request)
    try reply.consume(textOnlyTestDelta(request, text: String(repeating: "a", count: 262_144))) { _ in }
    #expect(throws: ClaudeTextOnlyRejection(failure: .outputLimitExceeded, code: .outputLimitExceeded)) {
        try reply.consume(textOnlyTestDelta(request, text: "b")) { _ in }
    }
    var (answer, _) = try initializedWorkBudgetStream(request)
    #expect(throws: ClaudeTextOnlyRejection(failure: .outputLimitExceeded, code: .outputLimitExceeded)) {
        try answer.consume(textOnlyTestResult(request, override: ["result": String(repeating: "a", count: 262_145)])) { _ in }
    }
}

/// One round carrying several parallel calls, each asked, answered and
/// finished, the way the CLI announces parallel reads in one assistant message.
private func workBudgetParallelRound(_ request: ClaudeTextOnlyRequest, round: Int, calls: Int) throws -> [Data] {
    let ids = (1...calls).map { "toolu_parallel_work_\(round)_\($0)" }
    let inputs = ids.indices.map { ["file_path": "/private/tmp/work-budget.noindex/round-\(round)-\($0).txt"] }
    var frames = [try textOnlyTestLine(["type": "assistant", "session_id": request.sessionID.uuidString,
        "message": ["id": "msg_parallel_work_\(round)", "role": "assistant", "model": request.expectedResolvedModel,
            "content": ids.indices.map { ["type": "tool_use", "id": ids[$0], "name": "Read", "input": inputs[$0]] }]])]
    for index in ids.indices {
        let questionID = "parallel-question-\(round)-\(index)"
        frames += [
            try textOnlyTestLine(["type": "control_request", "request_id": questionID,
                "request": ["subtype": "can_use_tool", "tool_name": "Read", "tool_use_id": ids[index], "input": inputs[index]]]),
            try textOnlyTestLine(["type": "control_response",
                "response": ["subtype": "success", "request_id": questionID, "response": ["behavior": "allow"]]]),
        ]
    }
    frames.append(try textOnlyTestLine(["type": "user", "session_id": request.sessionID.uuidString,
        "uuid": UUID().uuidString, "parent_tool_use_id": NSNull(),
        "message": ["role": "user", "content": ids.map {
            ["type": "tool_result", "tool_use_id": $0, "content": "Read.", "is_error": false] as [String: Any] }]]))
    return frames
}

@Test("Work's calls, questions and results outlast its rounds when each round reads three files at once")
func workCallBudgetCoversParallelRounds() throws {
    let request = try textOnlyTestRequest(workAccess: longWorkAccess())
    let budget = ClaudeTextOnlyStream.maximumGrantedToolUses + ClaudeTextOnlyStream.maximumWorkCalls
    // Three calls a round for all sixty-four rounds: the round cap, which the
    // CLI enforces, comes first, never the call budget mid-edit.
    #expect(budget >= 3 * 64)
    var (stream, _) = try initializedWorkBudgetStream(request)
    for round in 1...64 {
        for frame in try workBudgetParallelRound(request, round: round, calls: 3) {
            try stream.consume(frame) { _ in }
        }
    }
    #expect(stream.grantedToolUseCount == 192 && stream.grantedToolResultCount == 192)
    #expect(stream.permissionRequestCount == 192)
    // The call past the budget is still the app's own limit, as it starts.
    if budget > 192 {
        for call in 193...budget {
            for frame in try workBudgetRound(request, index: call, result: "Read.") {
                try stream.consume(frame) { _ in }
            }
        }
    }
    let extra = try #require(workBudgetRound(request, index: budget + 1, result: "Read.").first)
    #expect(throws: ClaudeTextOnlyRejection(failure: .turnLimitReached, code: .turnLimitReached)) {
        try stream.consume(extra) { _ in }
    }
}
