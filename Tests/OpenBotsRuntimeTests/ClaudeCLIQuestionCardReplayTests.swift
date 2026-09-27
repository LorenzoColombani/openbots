import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsRuntime

// A new bot's setup turn that looks around, sets itself up, then asks two
// question cards in a row and answers after the user's replies (Claude Code 2.1.283,
// Tests/.../claude-cli-2.1.283/question-cards/README.md). A setup turn of this
// shape once died after its second card; this one must replay whole.
@Test("Claude Code 2.1.283: a setup turn with a look, two question cards in a row and the answers replays whole")
func cli2_1_283QuestionCardsReplay() throws {
    let root = try #require(Bundle.module.url(forResource: "claude-cli-2.1.283", withExtension: nil, subdirectory: "Fixtures"))
    let folder = root.appendingPathComponent("question-cards")
    let meta = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("meta.json"))) as? [String: Any])
    let sessionText = try #require(meta["session_id"] as? String), messageText = try #require(meta["message_id"] as? String)
    let sessionID = try #require(UUID(uuidString: sessionText))
    let messageID = try #require(UUID(uuidString: messageText))
    let controlID = try #require(meta["control_id"] as? String)
    let model = try #require(meta["model"] as? String)
    let text = try #require(meta["text"] as? String)
    let readDirs = try #require(meta["read_dirs"] as? [String])
    let frames = try String(contentsOf: folder.appendingPathComponent("wire.jsonl"), encoding: .utf8)
        .split(separator: "\n").map { Data(($0 + "\n").utf8) }
    let target = try ClaudeConnectionTarget(
        executableURL: URL(fileURLWithPath: "/private/tmp/not-created-text.noindex/claude"),
        expectedExecutableSHA256: String(repeating: "a", count: 64),
        profileURL: URL(fileURLWithPath: "/private/tmp/not-created-text.noindex/profile"),
        workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/not-created-text.noindex/work"),
        temporaryDirectoryURL: URL(fileURLWithPath: "/private/tmp/not-created-text.noindex/temp"),
        homeDirectoryURL: URL(fileURLWithPath: "/private/tmp/not-created-text.noindex/home"))
    let reading = try ClaudeTextReadAccess(sharedDirectoryURL: URL(fileURLWithPath: readDirs[0]),
                                           skillsDirectoryURL: URL(fileURLWithPath: readDirs[1]), protectedPaths: [])
    let request = try ClaudeTextOnlyRequest(target: target, runID: UUID(), sessionID: sessionID, messageID: messageID,
        text: text, systemPrompt: "probe", model: model, readAccess: reading, grantsSelfSetup: true)
    let control = ClaudeTextTurnControl()
    var stream = ClaudeTextOnlyStream(request: request, control: control)
    stream.expectControlInitialization(requestID: controlID)
    var rejections: [String] = []
    var asked: [String] = []
    var finished: [String] = []
    var reply = ""
    for (index, frame) in frames.enumerated() {
        do {
            try stream.consume(frame) { event in
                switch event {
                case .permissionRequested(let question):
                    asked.append(question.toolName)
                    control.register(question)
                    control.respond(requestID: question.requestID, allow: question.admitted)
                case .selfSetupRequested(let call):
                    control.answerSelfSetup(requestID: call.requestID, text: "Set up as Picnic.", refused: false)
                case .toolFinished(let id, let failed):
                    #expect(!failed, "call \(id) failed")
                    finished.append(id)
                case .textSnapshot(let text):
                    reply = text
                default: break
                }
            }
        } catch let rejection as ClaudeTextOnlyRejection {
            let root = (try? JSONSerialization.jsonObject(with: frame) as? [String: Any]) ?? [:]
            rejections.append("frame \(index + 1) \(rejection.failure)/\(rejection.code): \(ClaudeTextOnlyStream.shapeDescription(root))")
        }
        _ = control.takePending()
    }
    #expect(rejections.isEmpty, "\(rejections)")
    #expect(stream.hasCompleted)
    #expect(asked == [ClaudeTextSelfSetupPolicy.qualifiedToolName, "AskUserQuestion", "AskUserQuestion"])
    #expect(finished.count == 4, "the look, the setup and both cards")
    #expect(!reply.isEmpty)
}
