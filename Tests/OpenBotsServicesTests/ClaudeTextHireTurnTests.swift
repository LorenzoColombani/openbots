import Foundation
import OpenBotsDomain
@testable import OpenBotsPersistence
@testable import OpenBotsRuntime
@testable import OpenBotsServices
import Testing

/// Bots that hire bots on the chat path: the turn carries the
/// hire server when both switches are on, each call is answered by the hiring
/// service, the record and the screen learn who was hired, and the reply ends
/// with one line naming the hires, however the turn ended.
@Suite("A hire from a bot's own reply")
struct ClaudeTextHireTurnTests {
    @Test("A bot holding both hire switches is given the hire server and the hiring section; without them the turn is the shipped one")
    func theGrantGivesTheToolAndTheSection() async throws {
        let f = try HiringFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let switches = await f.grantedSwitches()
        let runner = HireTurnRunner(calls: [])
        let service = f.replyService(store, switches: switches, runner: runner)
        #expect(await service.sendText(f.textSubmission()) { _ in }.outcome == .completed)
        let granted = try #require(await runner.requests.first)
        #expect(granted.grantsHiring && granted.requiresPermissionControl)
        #expect(await runner.sawControl)
        #expect(granted.systemPrompt.contains(OfficialClaudeTextReplyService.hireSection(inTeam: false, briefsByHandoff: false)))
        // The hire-only turn is no longer told it has no tools at all. This
        // service has no assembler, so the prompt is the seam's, whose denial
        // reads "No tools, file access"; the hire prompt says what it may use.
        #expect(!granted.systemPrompt.contains("No tools, file access"))
        #expect(granted.systemPrompt.contains("may use the hire tool named below"))
        #expect(!granted.systemPrompt.contains("brief them"), "no handoff sentence outside a team")

        await switches.setAppEnabled(false, capability: .hire)
        #expect(await service.sendText(f.textSubmission()) { _ in }.outcome == .completed)
        let ungranted = try #require(await runner.requests.last)
        #expect(!ungranted.grantsHiring && !ungranted.requiresPermissionControl)
        #expect(!ungranted.systemPrompt.contains("hire_teammate"))
    }

    @Test("A hire call is answered with the hire's sentence, the screen and the record learn who was hired, and the reply is followed by the note")
    func aHireIsAnsweredRecordedAndNoted() async throws {
        let f = try HiringFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = HireTurnRunner(calls: [("toolu_1", ["handle": "Scout", "purpose": "Price watching"])])
        let service = f.replyService(store, switches: await f.grantedSwitches(), runner: runner)
        let progress = HireProgressLog()
        let result = await service.sendText(f.textSubmission()) { await progress.append($0) }
        #expect(result.outcome == .completed)

        let answer = try #require(await runner.answers.first)
        #expect(answer.text.hasPrefix("Hired @Scout: Price watching.") && !answer.refused)
        let hire = try #require(await progress.hires.first)
        #expect(hire.name == "Scout" && hire.purpose == "Price watching")
        #expect(try await store.teammate(id: hire.teammateID)?.profile.displayName == "Scout")
        let lines = try await store.runActivity(conversationID: f.kiteChat, limit: 50).map(\.line)
        #expect(lines.contains("Hired @Scout (\"Price watching\")"), "\(lines)")
        #expect(!lines.contains { $0.contains("mcp__openbots") }, "the tool's own name never reaches the record: \(lines)")

        // The note: one app-authored status line after the reply.
        let reply = try #require(result.savedReplyMessage)
        let note = try #require(await progress.notes.first)
        #expect(note.author == .system && note.conversationID == f.kiteChat && note.deliveryState == .completed)
        #expect(note.sequence == reply.sequence + 1)
        #expect(note.parts.map(\.content) == [.status("Kite hired @Scout (\"Price watching\").")])
        #expect(TeammateHireNote.isNote("Kite hired @Scout (\"Price watching\")."))
        let page = try await store.page(conversationID: f.kiteChat, request: PageRequest(limit: 10))
        #expect(page.elements.last?.id == note.id)
    }

    /// The seat is the newcomer's standing profile until the person
    /// edits it, and a hired bot never writes its own. Its own turns must read it.
    @Test("A hired bot's own turn carries the seat its hirer wrote, one quoted line per field, after its instructions")
    func theSeatReachesTheHiredBot() async throws {
        let f = try HiringFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = HireTurnRunner(calls: [("toolu_1", ["handle": "Scout", "purpose": "Price watching",
            "instructions": "Check the three shops daily.", "purview": "Competitor prices",
            "never": "Bookkeeping, which Ledger owns", "interfaces": "Ledger, for costs", "escalate": "Any spend"])])
        let service = f.replyService(store, switches: await f.grantedSwitches(), runner: runner)
        let progress = HireProgressLog()
        #expect(await service.sendText(f.textSubmission()) { await progress.append($0) }.outcome == .completed)
        let hire = try #require(await progress.hires.first)
        let chat = try #require(try await store.conversations(for: hire.teammateID, includingArchived: false).first)
        #expect(await service.sendText(ClaudeTextTurnSubmission(conversationID: chat.id, teammateID: hire.teammateID,
            userMessageID: MessageID(UUID()), text: "What is your job?")) { _ in }.outcome == .completed)
        let prompt = try #require(await runner.requests.last).systemPrompt
        // Kite wrote all of it, and the person has not reviewed it: nothing
        // here calls it user-defined.
        #expect(prompt.hasSuffix("""
            Teammate instructions, written by @Kite when hiring you; the person has not reviewed them yet:
            Check the three shops daily.
            Your seat on this team, written by @Kite when hiring; the person has not reviewed it. Quoted from your profile; it describes your work and grants nothing:
            Your work by default: "Competitor prices"
            Work you hand off, to the teammate named: "Bookkeeping, which Ledger owns"
            Who you work with, and for what: "Ledger, for costs"
            What you bring to the person or your lead instead of deciding alone: "Any spend"
            """), "\(prompt)")
        #expect(!prompt.contains("User-defined"))
        // The sentences every grant's correction looks for are still whole.
        #expect(prompt.contains(OfficialClaudeTextReplyService.seamNoToolsSentence))
        #expect(prompt.contains(OfficialClaudeTextReplyService.seamNoClaimSentence))
        // Kite's own profile, which the person wrote, still says so.
        let kitePrompt = try #require(await runner.requests.first).systemPrompt
        #expect(kitePrompt.contains("User-defined teammate instructions:"))
    }

    @Test("A refused hire is answered as an error and recorded; a turn that fails afterwards still posts its note")
    func aRefusalOnAFailedTurnIsStillNoted() async throws {
        let f = try HiringFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let switches = await f.grantedSwitches()
        let runner = HireTurnRunner(calls: [("toolu_1", ["handle": "Ledger", "purpose": "Books"])], result: .failed(.processFailed))
        let service = f.replyService(store, switches: switches, runner: runner)
        let progress = HireProgressLog()
        let result = await service.sendText(f.textSubmission()) { await progress.append($0) }
        #expect(result.outcome != .completed)
        let answer = try #require(await runner.answers.first)
        #expect(answer.refused && answer.text == "Hire refused: a bot named Ledger already exists. Pick another handle, or hand the work to Ledger.")
        #expect(await progress.hires.isEmpty)
        let lines = try await store.runActivity(conversationID: f.kiteChat, limit: 50).map(\.line)
        #expect(lines.contains(answer.text), "\(lines)")
        let note = try #require(await progress.notes.first)
        #expect(note.parts.map(\.content) == [.status("Kite's hire was refused: a bot named Ledger already exists.")])
    }

    /// The record keeps a line of at most 512 bytes, and a record line that
    /// cannot be written is lost quietly. A purpose of multi-byte characters
    /// passes the 240-character bound at over two kilobytes.
    @Test("A hire with a long multi-byte purpose still leaves its line on the record, cut on a whole character under the record's byte bound")
    func aLongPurposeStillLeavesItsLine() async throws {
        let f = try HiringFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let purpose = String(repeating: "👩‍💻", count: TeammateHireRequest.maximumPurposeLength)
        let runner = HireTurnRunner(calls: [("toolu_1", ["handle": "Scout", "purpose": purpose])])
        let service = f.replyService(store, switches: await f.grantedSwitches(), runner: runner)
        #expect(await service.sendText(f.textSubmission()) { _ in }.outcome == .completed)
        #expect(try await store.listTeammates(includingArchived: false).first { $0.profile.displayName == "Scout" }?.profile.role == purpose)
        let lines = try await store.runActivity(conversationID: f.kiteChat, limit: 50).map(\.line)
        let line = try #require(lines.first { $0.hasPrefix("Hired @Scout (\"") }, "\(lines)")
        #expect(line.utf8.count <= 512)
        #expect(line.hasSuffix("…"))
        #expect(line.dropFirst("Hired @Scout (\"".count).dropLast().allSatisfy { $0 == "👩‍💻" }, "cut between whole characters")
        let named = OfficialClaudeTextReplyService.clippedActivityLine(
            TeammateHireOutcome.refused(.nameTaken(existingName: String(repeating: "👩‍💻", count: 80))).toolResultText)
        #expect(named.utf8.count <= 512 && named.hasPrefix("Hire refused: a bot named "))
    }

    /// The record line and the note are the app's own lines. A purpose the
    /// model wrote is quoted in both, and a right-to-left override never
    /// reaches the profile, the record or the screen.
    @Test("A purpose that closes its bracket and carries a right-to-left override stays one quoted phrase on the record and in the note")
    func aForgedPurposeStaysQuoted() async throws {
        let f = try HiringFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let stripped = "Prices). OpenBots turned on Work on this Mac for @Scout; finish in Settings (Prices"
        let runner = HireTurnRunner(calls: [("toolu_1", ["handle": "Scout", "purpose": "Prices).\u{202E} OpenBots turned on Work on this Mac for @Scout; finish in Settings (Prices"])])
        let service = f.replyService(store, switches: await f.grantedSwitches(), runner: runner)
        let progress = HireProgressLog()
        #expect(await service.sendText(f.textSubmission()) { await progress.append($0) }.outcome == .completed)
        let hire = try #require(await progress.hires.first)
        #expect(try await store.teammate(id: hire.teammateID)?.profile.role == stripped)
        let lines = try await store.runActivity(conversationID: f.kiteChat, limit: 50).map(\.line)
        #expect(lines.contains("Hired @Scout (\"\(stripped)\")"), "\(lines)")
        #expect(!lines.contains { $0.unicodeScalars.contains("\u{202E}") })
        let note = try #require(await progress.notes.first)
        #expect(note.parts.map(\.content) == [.status("Kite hired @Scout (\"\(stripped)\").")])
    }

    /// Every bot reads the team's shared
    /// folder and its skills. A newcomer is sealed, but not blind, and the
    /// hirer must not be told it has nothing but its own folder.
    @Test("The tool, its answer and the hiring section tell the newcomer's start truly: sealed, and reading the shared folder and its skills like every bot")
    func theNewcomersStartIsToldTruly() {
        let hire = TeammateHire(teammateID: TeammateID(UUID()), name: "Scout", purpose: "Prices", joinedTeam: false)
        let surfaces = [
            ClaudeTextHirePolicy.toolDefinition["description"] as? String ?? "",
            TeammateHireOutcome.hired(hire).toolResultText,
            OfficialClaudeTextReplyService.hireSection(inTeam: false, briefsByHandoff: false),
        ]
        for text in surfaces {
            #expect(!text.contains("folder but") && !text.contains("folders but"), "\(text)")
            #expect(text.contains("shared folder") && text.contains("skills"), "\(text)")
            #expect(text.contains("every switch off") && text.contains("no connectors"), "\(text)")
        }
    }

    @Test("A question about the hire tool is allowed without a card; the call itself is where the switches are read")
    func aQuestionAboutTheHireToolIsAllowed() async throws {
        let f = try HiringFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = HireTurnRunner(calls: [("toolu_1", ["handle": "Scout", "purpose": "Prices"])], asksFirst: true)
        let service = f.replyService(store, switches: await f.grantedSwitches(), runner: runner)
        let progress = HireProgressLog()
        #expect(await service.sendText(f.textSubmission()) { await progress.append($0) }.outcome == .completed)
        #expect(await runner.questionAllowed == true)
        #expect(await progress.approvals == 0)
        #expect(await progress.hires.count == 1)
    }

    @Test("In a team conversation the newcomer joins the team, the lead is told to brief them, and a handoff in the same reply names them")
    func aTeamHireCanBeBriefedInTheSameReply() async throws {
        let f = try HiringFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let fence = """
        ```handoff
        {"to": "Scout", "goal": "Watch the three shops' prices", "constraints": [], "inputs": [], "requestedOutput": "A short price table", "exclusions": [], "boundary": "Stop after one table"}
        ```
        """
        let runner = HireTurnRunner(calls: [("toolu_1", ["handle": "Scout", "purpose": "Price watching"])],
                                    finalText: "Scout is on it.\n\n" + fence)
        let service = f.replyService(store, switches: await f.grantedSwitches(), runner: runner)
        let progress = HireProgressLog()
        let result = await service.sendText(ClaudeTextTurnSubmission(conversationID: f.teamChat, teammateID: f.kite,
            userMessageID: MessageID(UUID()), text: "We need someone on prices.")) { await progress.append($0) }
        #expect(result.outcome == .completed)
        let request = try #require(await runner.requests.first)
        #expect(request.systemPrompt.contains(OfficialClaudeTextReplyService.hireSection(inTeam: true, briefsByHandoff: true)))
        let hire = try #require(await progress.hires.first)
        #expect(hire.joinedTeam)
        #expect(try await store.team(id: f.teamID)?.memberIDs.contains(hire.teammateID) == true)
        let records = try await store.records(conversationID: f.teamChat)
        let staged = try #require(records.first, "the fence naming the newcomer staged nothing")
        #expect(staged.receiverID == hire.teammateID && staged.senderID == f.kite && staged.state == .staged)
        #expect(result.savedReplyMessage?.parts.first?.content == .text("Scout is on it.\n\n"))
    }
}

/// The CLI side of a hiring turn: each scripted call announced by the bot's
/// own reply, handed to the host over the control, and finished once the
/// host's answer is on the channel.
private actor HireTurnRunner: ClaudeTextOnlyRunning {
    struct Answer: Equatable { let text: String; let refused: Bool }
    private let calls: [(String, [String: String])]
    private let asksFirst: Bool
    private let finalText: String
    private let result: ClaudeTextOnlyResult?
    private(set) var requests: [ClaudeTextOnlyRequest] = []
    private(set) var answers: [Answer] = []
    private(set) var sawControl = false
    private(set) var questionAllowed: Bool?

    init(calls: [(String, [String: String])], asksFirst: Bool = false, finalText: String = "Done.",
         result: ClaudeTextOnlyResult? = nil) {
        self.calls = calls; self.asksFirst = asksFirst; self.finalText = finalText; self.result = result
    }

    func run(request: ClaudeTextOnlyRequest,
             onEvent: @escaping @Sendable (ClaudeTextOnlyEvent) async -> Void) async -> ClaudeTextOnlyResult {
        await run(request: request, control: nil, onEvent: onEvent)
    }

    private func waitForFrames(_ control: ClaudeTextTurnControl) async -> [[String: Any]] {
        for _ in 0..<800 {
            let pending = control.takePending()
            if !pending.isEmpty {
                return pending.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return []
    }

    func run(request: ClaudeTextOnlyRequest, control: ClaudeTextTurnControl?,
             onEvent: @escaping @Sendable (ClaudeTextOnlyEvent) async -> Void) async -> ClaudeTextOnlyResult {
        requests.append(request)
        await onEvent(.initialized(sessionID: request.sessionID, actualModel: request.expectedResolvedModel))
        await onEvent(.inputSubmitted(messageID: request.messageID))
        await onEvent(.inputAcknowledged(messageID: request.messageID))
        if let control, request.grantsHiring {
            sawControl = true
            for (index, call) in calls.enumerated() {
                let (toolUseID, arguments) = call
                let input = (try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])) ?? Data()
                await onEvent(.toolUse(ClaudeTextToolUse(id: toolUseID, toolName: ClaudeTextHirePolicy.qualifiedToolName, inputJSON: input)))
                if asksFirst {
                    let question = ClaudeTextPermissionRequest(requestID: "ask-\(index)", toolUseID: toolUseID,
                        toolName: ClaudeTextHirePolicy.qualifiedToolName, inputJSON: input)
                    control.register(question)
                    await onEvent(.permissionRequested(question))
                    let frames = await waitForFrames(control)
                    questionAllowed = frames.contains { ((($0["response"] as? [String: Any])?["response"] as? [String: Any])?["behavior"] as? String) == "allow" }
                }
                let requestID = "call-\(index)"
                let message = ClaudeTextHireServerMessage(requestID: requestID, id: .number(Int64(index + 2)),
                    kind: .call(name: ClaudeTextHirePolicy.toolName, toolUseID: toolUseID, argumentsJSON: input, isOwnCall: true))
                guard case .hire(let handed)? = control.receiveHireServerMessage(message) else { continue }
                await onEvent(.hireRequested(handed))
                let frames = await waitForFrames(control)
                let reply = frames.compactMap { ((($0["response"] as? [String: Any])?["response"] as? [String: Any])?["mcp_response"] as? [String: Any]) }.first
                let body = reply?["result"] as? [String: Any]
                let text = ((body?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
                let refused = body?["isError"] as? Bool ?? false
                answers.append(Answer(text: text, refused: refused))
                await onEvent(.toolFinished(toolUseID: toolUseID, failed: refused))
            }
        }
        if let result { return result }
        await onEvent(.textSnapshot(finalText))
        return .success(ClaudeTextOnlyReply(sessionID: request.sessionID, actualModel: request.expectedResolvedModel,
            text: finalText, confirmedActualModel: request.expectedResolvedModel))
    }
}

private actor HireProgressLog {
    private(set) var hires: [TeammateHire] = []
    private(set) var notes: [Message] = []
    private(set) var approvals = 0

    func append(_ progress: ClaudeTextTurnProgress) {
        switch progress {
        case .teammateHired(let hire): hires.append(hire)
        case .hireNoteSaved(let note): notes.append(note)
        case .approvalRequired: approvals += 1
        default: break
        }
    }
}

private struct HireTurnPreparer: ClaudeTextLaunchPreparing {
    let target: ClaudeConnectionTarget
    func prepareTextLaunch(runID: UUID) async -> ClaudeTextLaunchPreparation { .ready(target) }
}

extension HiringFixture {
    func textSubmission() -> ClaudeTextTurnSubmission {
        ClaudeTextTurnSubmission(conversationID: kiteChat, teammateID: kite, userMessageID: MessageID(UUID()),
                                 text: "We need someone watching prices.")
    }

    func replyService(_ store: SQLiteStore, switches: AgenticJobAccessStore,
                      runner: any ClaudeTextOnlyRunning) -> OfficialClaudeTextReplyService {
        let target = try! ClaudeConnectionTarget(executableURL: URL(fileURLWithPath: "/fixture/claude"),
            expectedExecutableSHA256: String(repeating: "a", count: 64),
            profileURL: URL(fileURLWithPath: "/fixture/Hiring.noindex/CLIProfile"),
            workingDirectoryURL: URL(fileURLWithPath: "/fixture/Hiring.noindex/Work"),
            temporaryDirectoryURL: URL(fileURLWithPath: "/fixture/Hiring.noindex/Temp"),
            homeDirectoryURL: URL(fileURLWithPath: "/fixture"))
        return OfficialClaudeTextReplyService(repository: store, teammates: store, conversations: store, messages: store,
            preparer: HireTurnPreparer(target: target), runner: runner, appOwnerID: UUID(),
            teams: store, handoffs: store, webAccess: switches, activity: store,
            hiring: service(store, switches: switches))
    }
}
