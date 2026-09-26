import Foundation
import OpenBotsDomain
@testable import OpenBotsPersistence
@testable import OpenBotsRuntime
@testable import OpenBotsServices
import Testing

/// Gmail send on the chat path: Approve writes the
/// message's one-use approval before the allow goes out, and nothing else does.
@Suite("Gmail send on the chat path: only Approve writes the approval the helper sends on")
struct GmailSendTurnServiceTests {
    static var message: [String: Any] {
        ["from": "openbots@example.com", "to": "alex@example.com",
         "subject": "Hello", "body": "The whole message."]
    }

    @Test("Approve writes the message's digest, then allows the call")
    func approveWritesTheDigest() async throws {
        let f = try GmailSendTurnFixture(); defer { f.remove() }
        let (service, runner, progress, turn) = try await f.start()
        let card = try await progress.waitForApproval()
        #expect(card.title == "Send a Gmail message")
        #expect(card.detail.hasSuffix("\n\nThe whole message."))
        let digest = try GoogleGmailSendProposal(input: Self.message).digest
        #expect(!FileManager().fileExists(atPath: f.ledger.directory.appendingPathComponent(digest).path))
        #expect(await service.decideApproval(id: card.id, allow: true))
        let answer = try await runner.waitForAnswer()
        #expect(answer.contains("\"behavior\":\"allow\""), "\(answer)")
        #expect(FileManager().fileExists(atPath: f.ledger.directory.appendingPathComponent(digest).path))
        #expect(await turn.value.outcome == .completed)
    }

    @Test("Deny writes nothing")
    func denyWritesNothing() async throws {
        let f = try GmailSendTurnFixture(); defer { f.remove() }
        let (service, runner, progress, turn) = try await f.start()
        let card = try await progress.waitForApproval()
        #expect(await service.decideApproval(id: card.id, allow: false))
        #expect(try await runner.waitForAnswer().contains("\"behavior\":\"deny\""))
        #expect(!FileManager().fileExists(atPath: f.ledger.directory.path))
        #expect(await turn.value.outcome == .completed)
    }

    @Test("An approval that cannot be written is a refusal, and says so")
    func unwritableApprovalRefuses() async throws {
        let f = try GmailSendTurnFixture(ledgerUnderAFile: true); defer { f.remove() }
        let (service, runner, progress, turn) = try await f.start()
        let card = try await progress.waitForApproval()
        _ = await service.decideApproval(id: card.id, allow: true)
        let answer = try await runner.waitForAnswer()
        #expect(answer.contains("\"behavior\":\"deny\"") && answer.contains("could not be written"), "\(answer)")
        #expect(await turn.value.outcome == .completed)
    }
}

private enum GmailSendTestError: Error { case timedOut }

/// A child that asks one Gmail send and waits for the app's answer.
private actor GmailSendRunner: ClaudeTextOnlyRunning {
    private(set) var answer: String?

    func waitForAnswer() async throws -> String {
        for _ in 0..<800 {
            if let answer { return answer }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw GmailSendTestError.timedOut
    }

    func run(request: ClaudeTextOnlyRequest,
             onEvent: @escaping @Sendable (ClaudeTextOnlyEvent) async -> Void) async -> ClaudeTextOnlyResult {
        await run(request: request, control: nil, onEvent: onEvent)
    }

    func run(request: ClaudeTextOnlyRequest, control: ClaudeTextTurnControl?,
             onEvent: @escaping @Sendable (ClaudeTextOnlyEvent) async -> Void) async -> ClaudeTextOnlyResult {
        await onEvent(.initialized(sessionID: request.sessionID, actualModel: request.expectedResolvedModel))
        await onEvent(.inputSubmitted(messageID: request.messageID))
        await onEvent(.inputAcknowledged(messageID: request.messageID))
        if let control, let server = request.connectorAccess?.servers.first(where: { $0.role == .googleGmailSend }) {
            let data = (try? JSONSerialization.data(withJSONObject: GmailSendTurnServiceTests.message,
                                                    options: [.sortedKeys])) ?? Data()
            let toolName = server.toolNamespace + ClaudeTextGoogleGmailSendApprovalPolicy.sendTool
            await onEvent(.toolUse(ClaudeTextToolUse(id: "toolu_send", toolName: toolName, inputJSON: data)))
            let question = ClaudeTextPermissionRequest(requestID: "req-send", toolUseID: "toolu_send",
                                                       toolName: toolName, inputJSON: data)
            control.register(question)
            await onEvent(.permissionRequested(question))
            var allowed = false
            for _ in 0..<800 {
                if let first = control.takePending().first.map({ String(decoding: $0, as: UTF8.self) }) {
                    answer = first
                    allowed = first.contains("\"behavior\":\"allow\"")
                    break
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            await onEvent(.toolFinished(toolUseID: "toolu_send", failed: !allowed))
        }
        await onEvent(.textSnapshot("Done."))
        return .success(ClaudeTextOnlyReply(sessionID: request.sessionID, actualModel: request.expectedResolvedModel,
            text: "Done.", confirmedActualModel: request.expectedResolvedModel))
    }
}

private actor GmailSendProgressLog {
    private(set) var approvals: [ClaudeTextApproval] = []

    func append(_ progress: ClaudeTextTurnProgress) {
        if case .approvalRequired(let approval) = progress { approvals.append(approval) }
    }

    func waitForApproval() async throws -> ClaudeTextApproval {
        for _ in 0..<800 {
            if let first = approvals.first { return first }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw GmailSendTestError.timedOut
    }
}

private struct GmailSendAccess: ClaudeTextReplyWebAccessResolving {
    static let serverName = "openbots_" + String(repeating: "9", count: 64)

    func allowedTextReplyTools(teammateID: TeammateID) async -> Set<ClaudeTextOnlyTool> { [] }
    func webAccessChanges() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    func connectorAccess(teammateID: TeammateID, runID: UUID) async -> ClaudeTextConnectorAccess? {
        try? ClaudeTextConnectorAccess(servers: [
            ClaudeTextConnectorServer(name: Self.serverName, role: .googleGmailSend,
                program: .installedTool(URL(fileURLWithPath: "/private/tmp/openbots-gmail-send-fixture")),
                options: [], environment: [:]),
        ])
    }
    func grantedConnectorNames(teammateID: TeammateID) async -> Set<String> { [Self.serverName] }
}

private struct GmailSendPreparer: ClaudeTextLaunchPreparing {
    let target: ClaudeConnectionTarget
    func prepareTextLaunch(runID: UUID) async -> ClaudeTextLaunchPreparation { .ready(target) }
}

private struct GmailSendTurnFixture: Sendable {
    let directory: URL
    let ledger: GoogleGmailSendApprovalLedger
    let protection: ProtectionDecisionReceipt
    let kite = TeammateID(UUID())
    let chat = ConversationID(UUID())
    let date = Date(timeIntervalSince1970: 4_000)

    init(ledgerUnderAFile: Bool = false) throws {
        directory = URL(fileURLWithPath: "/private/tmp/OpenBotsNextGmailSend-\(UUID()).noindex", isDirectory: true)
        protection = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        if ledgerUnderAFile {
            let file = directory.appendingPathComponent("not-a-folder")
            try Data("x".utf8).write(to: file)
            ledger = GoogleGmailSendApprovalLedger(directory: file.appendingPathComponent("GmailSendApprovals"))
        } else {
            ledger = GoogleGmailSendApprovalLedger(directory: directory.appendingPathComponent("GmailSendApprovals"))
        }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func start() async throws -> (OfficialClaudeTextReplyService, GmailSendRunner, GmailSendProgressLog,
                                  Task<ClaudeTextTurnResult, Never>) {
        let store = try SQLiteStore(configuration: SQLiteStoreConfiguration(
            fileURL: directory.appendingPathComponent("control.sqlite"),
            protection: .ordinarySQLite(decision: protection)))
        let teammate = try Teammate(id: kite,
            profile: TeammateProfile(displayName: "Kite", role: "Teammate", detailedInstructions: nil),
            appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 9,
                silhouette: "round", paletteToken: "sky", eyeDialect: "bright",
                nonColorIdentityCue: "single crest", accessibleIdentityDescription: "Round creature with a crest"),
            createdAt: date, updatedAt: date)
        try await store.provisionDirectChat(teammate: teammate,
            conversation: Conversation(id: chat, kind: .direct(teammateID: kite), createdAt: date, updatedAt: date),
            fixtureGreeting: nil, selectConversation: false)
        let target = try ClaudeConnectionTarget(executableURL: URL(fileURLWithPath: "/fixture/claude"),
            expectedExecutableSHA256: String(repeating: "a", count: 64),
            profileURL: URL(fileURLWithPath: "/fixture/GmailSend.noindex/CLIProfile"),
            workingDirectoryURL: URL(fileURLWithPath: "/fixture/GmailSend.noindex/Work"),
            temporaryDirectoryURL: URL(fileURLWithPath: "/fixture/GmailSend.noindex/Temp"),
            homeDirectoryURL: URL(fileURLWithPath: "/fixture"))
        let runner = GmailSendRunner()
        let service = OfficialClaudeTextReplyService(repository: store, teammates: store, conversations: store,
            messages: store, preparer: GmailSendPreparer(target: target), runner: runner,
            appOwnerID: UUID(), webAccess: GmailSendAccess(), approvals: store, activity: store,
            gmailSendLedger: ledger)
        let progress = GmailSendProgressLog()
        let submission = ClaudeTextTurnSubmission(conversationID: chat, teammateID: kite,
            userMessageID: MessageID(UUID()), text: "Send Alex a hello.")
        let turn = Task { await service.sendText(submission) { await progress.append($0) } }
        return (service, runner, progress, turn)
    }
}
