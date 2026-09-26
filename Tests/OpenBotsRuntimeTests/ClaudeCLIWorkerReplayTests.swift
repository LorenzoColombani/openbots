import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsRuntime

// A throwaway worker is one blank reading turn: no
// control channel, no cards, no session kept; it reads the folders its holder's
// own turn reaches and writes nothing. The real wire of that shape, replayed
// through the parser (Fixtures/claude-cli-2.1.280/worker-probe, captured with
// the holder's folder holding three one-page PDFs as the read folder, an
// `appsupport` folder with the run folder inside it as the app's own protected
// folder, no allow rule, as the app writes none, and the worker's system prompt;
// paths scrubbed, the neutral run folder then written back, since a scrubber
// cannot find a path the stream split across two text deltas and the reply would
// no longer match its result):
//   w1-three-pdfs  a Glob of the holder's folder, a Read of each PDF, a Read
//                  outside every folder (a `permission_denied` frame), and the
//                  three summaries. 2.1.280 still forces `default` mode under
//                  the scrubbed environment and says so on stderr; nothing asks.

private let runRoot = "/private/tmp/worker-probe.noindex"

private struct WorkerProbeCapture {
    let sessionID: UUID
    let messageID: UUID
    let prompt: String
    let model: String
    let systemPrompt: String
    let argv: [String]
    let frames: [Data]

    init(run: String) throws {
        let root = try #require(Bundle.module.url(forResource: "claude-cli-2.1.280", withExtension: nil, subdirectory: "Fixtures"))
        let folder = root.appendingPathComponent("worker-probe").appendingPathComponent(run)
        let argvRecord = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("argv.json"))) as? [String: Any])
        let meta = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("meta.json"))) as? [String: Any])
        let session = try #require(argvRecord["session_id"] as? String)
        let message = try #require(argvRecord["message_id"] as? String)
        sessionID = try #require(UUID(uuidString: session))
        messageID = try #require(UUID(uuidString: message))
        prompt = try #require(meta["prompt"] as? String)
        model = try #require(meta["model"] as? String)
        systemPrompt = try String(contentsOf: folder.appendingPathComponent("system-prompt.md"), encoding: .utf8)
        argv = try #require(argvRecord["argv"] as? [String])
        var frames: [Data] = []
        for line in try String(contentsOf: folder.appendingPathComponent("wire.jsonl"), encoding: .utf8).split(separator: "\n") {
            let record = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            guard record["dir"] as? String == "cli", var frame = record["frame"] as? [String: Any] else { continue }
            if frame["type"] as? String == "system", frame["subtype"] as? String == "init",
               frame["apiKeySource"] as? String == "redacted" { frame["apiKeySource"] = "none" }
            var data = try JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys])
            data.append(0x0a)
            frames.append(data)
        }
        self.frames = frames
    }

    /// The worker's request as the app builds it: the holder's folder read,
    /// the app's own data protected, nothing else granted.
    func request() throws -> ClaudeTextOnlyRequest {
        let read = try ClaudeTextReadAccess(folderURLs: [URL(fileURLWithPath: "\(runRoot)/Holder")],
                                            protectedPaths: ["\(runRoot)/appsupport"])
        let target = try ClaudeConnectionTarget(
            executableURL: URL(fileURLWithPath: "/private/tmp/not-created-text.noindex/claude"),
            expectedExecutableSHA256: String(repeating: "a", count: 64),
            profileURL: URL(fileURLWithPath: "/private/tmp/not-created-text.noindex/profile"),
            workingDirectoryURL: URL(fileURLWithPath: "\(runRoot)/appsupport/Runtime/Claude/TextTurns/run1/Work.noindex"),
            temporaryDirectoryURL: URL(fileURLWithPath: "/private/tmp/not-created-text.noindex/temp"),
            homeDirectoryURL: URL(fileURLWithPath: "/private/tmp/not-created-text.noindex/home"))
        return try ClaudeTextOnlyRequest(target: target, runID: UUID(), sessionID: sessionID, messageID: messageID,
            text: prompt, systemPrompt: systemPrompt, model: model, readAccess: read)
    }
}

private func flag(_ arguments: [String], _ name: String) -> String? {
    arguments.firstIndex(of: name).map { arguments[$0 + 1] }
}

private func permissions(_ settings: String?) throws -> [String: Any] {
    let text = try #require(settings)
    let object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    return try #require(object["permissions"] as? [String: Any])
}

@Test("Claude Code 2.1.280: the worker's command is the probed one, flag for flag where the app decides")
func cli2_1_280WorkerCommandMatchesTheProbe() throws {
    let capture = try WorkerProbeCapture(run: "w1-three-pdfs")
    let request = try capture.request()
    #expect(request.grantsReading && !request.requiresPermissionControl && !request.grantsWork && !request.carriesAppServer)
    #expect(!request.persistsSession && !request.resumesSession)
    let arguments = ClaudeTextOnlyCommandBuilder.arguments(for: request)
    for name in ["--tools", "--disallowedTools", "--permission-mode", "--add-dir", "--mcp-config"] {
        #expect(flag(arguments, name) == flag(capture.argv, name), "\(name) differs")
    }
    for switchFlag in ["--safe-mode", "--restricted", "--no-session-persistence", "--strict-mcp-config"] {
        #expect(arguments.contains(switchFlag) && capture.argv.contains(switchFlag), "\(switchFlag)")
    }
    #expect(!arguments.contains("--permission-prompt-tool") && !arguments.contains("--agents"))
    let app = try permissions(flag(arguments, "--settings"))
    let probe = try permissions(flag(capture.argv, "--settings"))
    #expect(app["defaultMode"] as? String == probe["defaultMode"] as? String)
    #expect(app["deny"] as? [String] == probe["deny"] as? [String])
    #expect((app["allow"] as? [String] ?? []) == (probe["allow"] as? [String] ?? []))
}

@Test("Claude Code 2.1.280: a worker's run replays whole; it reads the three PDFs, the CLI refuses the read outside, and the summaries arrive")
func cli2_1_280WorkerRunReplays() throws {
    let capture = try WorkerProbeCapture(run: "w1-three-pdfs")
    let request = try capture.request()
    var stream = ClaudeTextOnlyStream(request: request)
    var events: [ClaudeTextOnlyEvent] = []
    var rejections: [String] = []
    for (index, frame) in capture.frames.enumerated() {
        do {
            try stream.consume(frame) { events.append($0) }
        } catch let rejection as ClaudeTextOnlyRejection {
            let root = (try? JSONSerialization.jsonObject(with: frame) as? [String: Any]) ?? [:]
            rejections.append("frame \(index + 1) \(rejection.failure)/\(rejection.code): \(ClaudeTextOnlyStream.shapeDescription(root))")
        }
    }
    #expect(rejections.isEmpty, "\(rejections)")
    #expect(stream.hasCompleted)
    guard case .success(let reply) = stream.finish(exitCode: 0) else { Issue.record("the worker did not finish"); return }
    for fact in ["TALL-HERON", "Reinette", "162 km"] { #expect(reply.text.contains(fact), "missing \(fact)") }
    let refused = events.compactMap { event -> String? in
        if case .toolRefused(_, let name) = event { return name }; return nil
    }
    #expect(refused == ["Read"])
    let uses = events.compactMap { event -> String? in
        if case .toolUse(let use) = event { return use.toolName }; return nil
    }
    #expect(uses.sorted() == ["Glob", "Read", "Read", "Read", "Read"])
}
