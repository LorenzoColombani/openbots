import Foundation
import OpenBotsDomain
@testable import OpenBotsPersistence
@testable import OpenBotsRuntime
@testable import OpenBotsServices
import Testing

/// A new bot sets itself up on the chat path: the turn of
/// a bot waiting for setup carries the tool in its direct chat, the switches it
/// asks for go on one card (Deny runs the call with none), the setup lands, the
/// reply is followed by one line, and the next turn carries the new switches.
@Suite("A new bot sets itself up from the user's first answer")
struct ClaudeTextSelfSetupTurnTests {
    private struct Turning {
        let f: HiringFixture
        let store: SQLiteStore
        let switches: AgenticJobAccessStore
        let setup: BotSelfSetupService
        let bot: TeammateID
        let chat: ConversationID
    }

    private func newBot(_ f: HiringFixture) async throws -> Turning {
        let store = try f.open()
        try await f.seed(store)
        let chats = DurableTeammateChatService(teammateRepository: store, conversationRepository: store,
            messageRepository: store, provisioningRepository: store, selectionRepository: store)
        let id = TeammateID(UUID())
        let created = try await chats.createSelfSettingTeammateAndDirectChat(teammateID: id, placeholderName: "New Bot",
            appearance: try CreatureAllocation(id: id.rawValue).appearance())
        let switches = AgenticJobAccessStore(reportWriteFailure: { _ in })
        await switches.setAppEnabled(true, capability: .web(.search))
        await switches.setAppEnabled(true, capability: .web(.fetch))
        let setup = BotSelfSetupService(repository: store, teammates: store, switches: switches)
        return Turning(f: f, store: store, switches: switches, setup: setup, bot: id, chat: created.conversation.id)
    }

    private func service(_ t: Turning, runner: any ClaudeTextOnlyRunning) -> OfficialClaudeTextReplyService {
        let target = try! ClaudeConnectionTarget(executableURL: URL(fileURLWithPath: "/fixture/claude"),
            expectedExecutableSHA256: String(repeating: "a", count: 64),
            profileURL: URL(fileURLWithPath: "/fixture/Setup.noindex/CLIProfile"),
            workingDirectoryURL: URL(fileURLWithPath: "/fixture/Setup.noindex/Work"),
            temporaryDirectoryURL: URL(fileURLWithPath: "/fixture/Setup.noindex/Temp"),
            homeDirectoryURL: URL(fileURLWithPath: "/fixture"))
        return OfficialClaudeTextReplyService(repository: t.store, teammates: t.store, conversations: t.store,
            messages: t.store, preparer: SetupTurnPreparer(target: target), runner: runner, appOwnerID: UUID(),
            teams: t.store, handoffs: t.store, webAccess: t.switches, approvals: t.store, activity: t.store,
            selfSetup: t.setup)
    }

    private func answer(_ t: Turning, _ text: String = "you watch my competitors' prices and tell me when they drop")
        -> ClaudeTextTurnSubmission {
        ClaudeTextTurnSubmission(conversationID: t.chat, teammateID: t.bot, userMessageID: MessageID(UUID()), text: text)
    }

    nonisolated(unsafe) private static let priceWatch: [String: Any] = [
        "handle": "PriceWatch", "purpose": "Watches competitor prices and flags drops",
        "instructions": "Check each product page and report drops first.", "switches": ["web_search", "web_fetch"]]

    /// Sends one answer; when a card goes up, `decide` answers it through the service.
    private func send(_ t: Turning, _ service: OfficialClaudeTextReplyService, decide: Bool?) async
        -> (ClaudeTextTurnResult, SetupProgressLog) {
        let log = SetupProgressLog()
        let turn = Task { await service.sendText(answer(t)) { await log.append($0) } }
        if let decide {
            for _ in 0..<500 {
                if let card = await log.cards.first {
                    _ = await service.decideApproval(id: card.id, allow: decide)
                    break
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        return (await turn.value, log)
    }

    @Test("The first answer's context says nothing was left out: the bot's own question is not quoted, and not counted")
    func firstTurnContextIsWhole() async throws {
        // Seen live: "tell me" in the user's answer matched the opening
        // question in the older-message search; the question is never quoted
        // (a bot line no message of the user's came before), and it was counted as
        // left out, so the first reply said "Some earlier messages or saved
        // memory were not included in this reply."
        let f = try HiringFixture(); defer { f.remove() }
        let t = try await newBot(f)
        let teammate = try #require(try await t.store.listTeammates(includingArchived: false).first { $0.id == t.bot })
        let selection = try #require(try await t.store.loadContext(conversationID: t.chat))
        let text = "you watch my competitors' prices and tell me when they drop"
        let terms = ReadContextRequest.literalSearchTerms(from: text)
        let loaded = try await t.store.loadReadContextCandidates(ReadContextRequest(conversationID: t.chat,
            teammateID: t.bot, profileRevision: teammate.profile.revision, selection: selection, beforeSequence: 2,
            searchTerms: terms))
        #expect(loaded.recentMessages.isEmpty && loaded.olderMessages.isEmpty)
        #expect(loaded.omissions.excludedMessageLowerBound == 0)
        let assembled = try await ClaudeContextAssemblyService(memoryReader: { _, _ in "" }).assemble(
            ClaudeContextAssemblyInput(teammate: teammate, currentText: text, snapshot: loaded))
        #expect(!assembled.disclosure.unavailableContext)
        #expect(assembled.receipt.messages.isEmpty, "the question is still never quoted")
    }

    @Test("Deleting a bot still waiting for setup takes its waiting mark with it")
    func deleteTakesTheMark() async throws {
        // Seen live: a bot whose first turn died was deleted and
        // its bot_self_setup_v1 key stayed behind with no bot.
        let f = try HiringFixture(); defer { f.remove() }
        let t = try await newBot(f)
        #expect(try await t.store.pendingSelfSetupName(teammateID: t.bot) == "New Bot")
        let teammate = try #require(try await t.store.listTeammates(includingArchived: false).first { $0.id == t.bot })
        _ = try await t.store.deleteTeammate(id: t.bot, expectedProfileRevision: teammate.profile.revision, now: Date())
        #expect(try await t.store.pendingSelfSetupName(teammateID: t.bot) == nil)
    }

    @Test("Only a bot waiting for setup, in its direct chat, gets the tool and the section; it is never pre-approved")
    func theGrant() async throws {
        let f = try HiringFixture(); defer { f.remove() }
        let t = try await newBot(f)
        let runner = SetupTurnRunner(call: nil)
        let service = service(t, runner: runner)
        #expect(await service.sendText(answer(t)) { _ in }.outcome == .completed)
        let granted = try #require(await runner.requests.first)
        #expect(granted.grantsSelfSetup && granted.requiresPermissionControl && granted.carriesAppServer)
        #expect(granted.appServerToolNames == [ClaudeTextSelfSetupPolicy.qualifiedToolName])
        #expect(!ClaudeTextOnlyCommandBuilder.preApprovedNames(for: granted).contains(ClaudeTextSelfSetupPolicy.qualifiedToolName),
                "its permission question is the switch card")
        #expect(granted.systemPrompt.contains(OfficialClaudeTextReplyService.selfSetupSection))
        // A Chrome job asked for Work without this (seen live).
        #expect(granted.systemPrompt.contains("Your apps and accounts are not switches here")
                && granted.systemPrompt.contains("do not ask for work in its place"))
        #expect(granted.systemPrompt.contains("may use the set_up_self tool named below"))
        #expect(!granted.systemPrompt.contains("No tools, file access"))

        // Kite is not waiting; and a waiting bot in a team chat is not offered it either.
        #expect(await service.sendText(f.textSubmission()) { _ in }.outcome == .completed)
        #expect(!(try #require(await runner.requests.last)).grantsSelfSetup)
        try await t.store.setPendingSelfSetup(teammateID: f.kite, placeholderName: "Kite")
        let team = ClaudeTextTurnSubmission(conversationID: f.teamChat, teammateID: f.kite,
                                            userMessageID: MessageID(UUID()), text: "Hello team")
        _ = await service.sendText(team) { _ in }
        #expect(await runner.requests.count == 3)
        #expect(!(try #require(await runner.requests.last)).grantsSelfSetup)
    }

    @Test("Approve: the card names the switches, the setup lands, the reply is followed by one line, and the next turn has the web")
    func approved() async throws {
        let f = try HiringFixture(); defer { f.remove() }
        let t = try await newBot(f)
        let runner = SetupTurnRunner(call: Self.priceWatch)
        let service = service(t, runner: runner)
        let (result, log) = await send(t, service, decide: true)
        #expect(result.outcome == .completed)

        let card = try #require(await log.cards.first)
        #expect(card.title == "Switches for PriceWatch")
        #expect(card.detail.hasPrefix("New Bot wants to become PriceWatch: \"Watches competitor prices and flags drops\"."))
        #expect(card.detail.contains("it asks for web search and web fetch, for this bot only"))
        #expect(await runner.ranWith?.switches == [.webSearch, .webFetch])
        let toolAnswer = try #require(await runner.answer)
        #expect(!toolAnswer.refused && toolAnswer.text.hasPrefix("You are set up as PriceWatch"))

        let bot = try #require(try await t.store.teammate(id: t.bot))
        #expect(bot.profile.displayName == "PriceWatch" && bot.profile.role == "Watches competitor prices and flags drops")
        let access = await t.switches.current(teammateID: t.bot)
        #expect(access.webSearch.isEnabled && access.webFetch.isEnabled && !access.work.botEnabled)
        #expect(await log.setUps == [t.bot])

        let reply = try #require(result.savedReplyMessage)
        let note = try #require(await log.notes.first)
        #expect(note.author == .system && note.sequence == reply.sequence + 1)
        #expect(note.parts.map(\.content) == [.status(
            "New Bot set itself up as PriceWatch (\"Watches competitor prices and flags drops\"). Turned on for it: web search and web fetch.")])
        let lines = try await t.store.runActivity(conversationID: t.chat, limit: 50).map(\.line)
        #expect(lines.contains("Asked to turn on web search and web fetch"), "\(lines)")
        #expect(lines.contains("Set itself up as PriceWatch"), "\(lines)")

        // The next turn: the web switches, the new name, no setup tool.
        #expect(await service.sendText(answer(t, "Start with the shop on example.com")) { _ in }.outcome == .completed)
        let next = try #require(await runner.requests.last)
        #expect(!next.grantsSelfSetup && next.allowedTools == [.webSearch, .webFetch])
        #expect(next.systemPrompt.contains("PriceWatch") && !next.systemPrompt.contains("set_up_self"))
    }

    @Test("Deny keeps the switches off, not the setup: the call runs with none and the profile is still written")
    func denied() async throws {
        let f = try HiringFixture(); defer { f.remove() }
        let t = try await newBot(f)
        let runner = SetupTurnRunner(call: Self.priceWatch)
        let (result, log) = await send(t, service(t, runner: runner), decide: false)
        #expect(result.outcome == .completed)
        #expect(await runner.ranWith?.switches == [])
        #expect(try await t.store.teammate(id: t.bot)?.profile.displayName == "PriceWatch")
        let access = await t.switches.current(teammateID: t.bot)
        #expect(!access.webSearch.botEnabled && !access.webFetch.botEnabled)
        #expect(await log.notes.first?.parts.map(\.content) == [.status(
            "New Bot set itself up as PriceWatch (\"Watches competitor prices and flags drops\"). No switches turned on.")])
        // The record says both truths: the switches were denied, the setup happened.
        let lines = try await t.store.runActivity(conversationID: t.chat, limit: 50).map(\.line)
        #expect(lines.contains("Denied: switches for pricewatch"), "\(lines)")
        #expect(lines.contains("Set itself up as PriceWatch"), "\(lines)")
    }

    @Test("A setup that asks for no switch shows no card and runs at once")
    func noSwitchNoCard() async throws {
        let f = try HiringFixture(); defer { f.remove() }
        let t = try await newBot(f)
        let runner = SetupTurnRunner(call: ["handle": "Poet", "purpose": "Writes short poems", "switches": []])
        let (result, log) = await send(t, service(t, runner: runner), decide: nil)
        #expect(result.outcome == .completed)
        #expect(await log.cards.isEmpty)
        #expect(try await t.store.teammate(id: t.bot)?.profile.displayName == "Poet")
    }
}

/// Plays the recorded shape (fixture `self-setup-probe/s2-competitor-prices`): the tool use, its
/// permission question, then the call with whatever the answer let through.
private actor SetupTurnRunner: ClaudeTextOnlyRunning {
    struct Answer: Equatable { let text: String; let refused: Bool }
    private let call: [String: Any]?
    private(set) var requests: [ClaudeTextOnlyRequest] = []
    private(set) var ranWith: BotSelfSetupRequest?
    private(set) var answer: Answer?

    init(call: [String: Any]?) { self.call = call }

    func run(request: ClaudeTextOnlyRequest,
             onEvent: @escaping @Sendable (ClaudeTextOnlyEvent) async -> Void) async -> ClaudeTextOnlyResult {
        await run(request: request, control: nil, onEvent: onEvent)
    }

    private func frames(_ control: ClaudeTextTurnControl) async -> [[String: Any]] {
        for _ in 0..<800 {
            let pending = control.takePending()
            if !pending.isEmpty { return pending.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
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
        if let control, request.grantsSelfSetup, let call {
            let input = (try? JSONSerialization.data(withJSONObject: call, options: [.sortedKeys])) ?? Data()
            await onEvent(.toolUse(ClaudeTextToolUse(id: "toolu_setup", toolName: ClaudeTextSelfSetupPolicy.qualifiedToolName,
                                                     inputJSON: input)))
            let question = ClaudeTextPermissionRequest(requestID: "ask-setup", toolUseID: "toolu_setup",
                toolName: ClaudeTextSelfSetupPolicy.qualifiedToolName, inputJSON: input)
            control.register(question)
            await onEvent(.permissionRequested(question))
            let decision = (await frames(control)).compactMap { ($0["response"] as? [String: Any])?["response"] as? [String: Any] }.first
            if decision?["behavior"] as? String == "allow", let updated = decision?["updatedInput"] as? [String: Any],
               let arguments = try? JSONSerialization.data(withJSONObject: updated, options: [.sortedKeys]) {
                ranWith = try? BotSelfSetupRequest.parse(argumentsJSON: arguments).get()
                let message = ClaudeTextHireServerMessage(requestID: "call-setup", id: .number(2),
                    kind: .call(name: ClaudeTextSelfSetupPolicy.toolName, toolUseID: "toolu_setup",
                                argumentsJSON: arguments, isOwnCall: true))
                if case .selfSetup(let handed)? = control.receiveHireServerMessage(message, offering: request.appServerToolNames) {
                    await onEvent(.selfSetupRequested(handed))
                    let reply = (await frames(control)).compactMap {
                        (($0["response"] as? [String: Any])?["response"] as? [String: Any])?["mcp_response"] as? [String: Any] }.first
                    let body = reply?["result"] as? [String: Any]
                    answer = Answer(text: ((body?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "",
                                    refused: body?["isError"] as? Bool ?? false)
                    await onEvent(.toolFinished(toolUseID: "toolu_setup", failed: answer?.refused ?? true))
                }
            }
        }
        let text = "I'm set up."
        await onEvent(.textSnapshot(text))
        return .success(ClaudeTextOnlyReply(sessionID: request.sessionID, actualModel: request.expectedResolvedModel,
            text: text, confirmedActualModel: request.expectedResolvedModel))
    }
}

private actor SetupProgressLog {
    private(set) var cards: [ClaudeTextApproval] = []
    private(set) var notes: [Message] = []
    private(set) var setUps: [TeammateID] = []

    func append(_ progress: ClaudeTextTurnProgress) {
        switch progress {
        case .approvalRequired(let approval): cards.append(approval)
        case .selfSetupNoteSaved(let note): notes.append(note)
        case .selfSetUp(let id, _): setUps.append(id)
        default: break
        }
    }
}

private struct SetupTurnPreparer: ClaudeTextLaunchPreparing {
    let target: ClaudeConnectionTarget
    func prepareTextLaunch(runID: UUID) async -> ClaudeTextLaunchPreparation { .ready(target) }
}
