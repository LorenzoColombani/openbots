import Foundation
import OpenBotsDomain
@testable import OpenBotsPersistence
import OpenBotsRuntime
@testable import OpenBotsServices
import Testing

/// The house-style block every teammate turn carries. Asserted by distinctive
/// substrings rather than the whole constant, so the block's own line wrapping
/// is pinned in one place only. Shared by the other services suites that check
/// a turn's system prompt.
func expectTeammateHouseStyle(_ prompt: String, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(prompt.contains("How you talk:"), sourceLocation: sourceLocation)
    #expect(prompt.contains("not the way a report reads"), sourceLocation: sourceLocation)
    #expect(prompt.contains("no summary of what you just said"), sourceLocation: sourceLocation)
    #expect(prompt.contains("Say \"I don't know\" plainly when you don't."), sourceLocation: sourceLocation)
    // The two rules that came out of the Canobi diagnosis: match the asker's
    // length, and keep orchestration out of the user channel.
    #expect(prompt.contains("Match the length of what you were asked."), sourceLocation: sourceLocation)
    #expect(prompt.contains("Delegation is not conversation."), sourceLocation: sourceLocation)
    // The block reaches a turn exactly once, whichever prompt builder made it.
    #expect(prompt.components(separatedBy: "How you talk:").count == 2, sourceLocation: sourceLocation)
    // A turn saves one reply and can attach nothing, so the voice never tells
    // a bot to hold a point for a later message or to move it into a document.
    #expect(!prompt.contains("say the first and stop"), sourceLocation: sourceLocation)
    #expect(!prompt.contains("The second can be its own message"), sourceLocation: sourceLocation)
    #expect(!prompt.contains("belongs in a document or an attachment"), sourceLocation: sourceLocation)
}

private actor TeamReplyRunner: ClaudeTextOnlyRunning {
    private(set) var requests: [ClaudeTextOnlyRequest] = []
    func run(request: ClaudeTextOnlyRequest,
             onEvent: @escaping @Sendable (ClaudeTextOnlyEvent) async -> Void) async -> ClaudeTextOnlyResult {
        requests.append(request)
        await onEvent(.initialized(sessionID: request.sessionID, actualModel: request.expectedResolvedModel))
        await onEvent(.inputSubmitted(messageID: request.messageID))
        await onEvent(.inputAcknowledged(messageID: request.messageID))
        await onEvent(.textSnapshot("Team reply"))
        return .success(ClaudeTextOnlyReply(sessionID: request.sessionID, actualModel: request.expectedResolvedModel, text: "Team reply."))
    }
}

private actor TeamReplyPreparer: ClaudeTextLaunchPreparing {
    let target: ClaudeConnectionTarget
    private(set) var calls = 0
    init(target: ClaudeConnectionTarget) { self.target = target }
    func prepareTextLaunch(runID: UUID) async -> ClaudeTextLaunchPreparation { calls += 1; return .ready(target) }
    func prepareTextLaunch(runID: UUID, model: String) async -> ClaudeTextLaunchPreparation { await prepareTextLaunch(runID: runID) }
    func prepareTextLaunch(runID: UUID, selection: ClaudeExecutionSelection) async -> ClaudeTextLaunchPreparation { await prepareTextLaunch(runID: runID) }
}

@Suite("Text replies in a team conversation")
struct TeamTextReplyTests {
    struct Fixture {
        let directory: URL
        let receipt: ProtectionDecisionReceipt
        let date = Date(timeIntervalSince1970: 4_000)
        let appOwner = UUID()
        let ada = TeammateID(UUID()), mira = TeammateID(UUID()), zed = TeammateID(UUID())
        let teamID = TeamID(UUID()), teamChat = ConversationID(UUID())
        init() throws {
            directory = URL(fileURLWithPath: "/private/tmp/OpenBotsNextTeamTextReply-\(UUID()).noindex", isDirectory: true)
            receipt = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
        func open() throws -> SQLiteStore {
            try SQLiteStore(configuration: SQLiteStoreConfiguration(fileURL: directory.appendingPathComponent("control.sqlite"),
                protection: .ordinarySQLite(decision: receipt)))
        }
        func seed(_ store: SQLiteStore, leadInstructions: String? = nil) async throws {
            for (id, name, role) in [(ada, "Ada", "Source verifier"), (mira, "Mira", "Research lead"), (zed, "Zed", "Outsider")] {
                let bot = try Teammate(id: id, profile: TeammateProfile(displayName: name, role: role,
                        detailedInstructions: id == mira ? leadInstructions : nil),
                    appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 6, silhouette: "round",
                        paletteToken: "sky", eyeDialect: "bright", nonColorIdentityCue: "single crest", accessibleIdentityDescription: "Round creature with a crest"),
                    createdAt: date, updatedAt: date)
                try await store.provisionDirectChat(teammate: bot,
                    conversation: Conversation(id: ConversationID(UUID()), kind: .direct(teammateID: id), createdAt: date, updatedAt: date),
                    fixtureGreeting: nil, selectConversation: false)
            }
            try await store.provisionTeam(Team(id: teamID, name: "QA Team", leadID: mira, memberIDs: [ada, mira], createdAt: date, updatedAt: date),
                conversation: Conversation(id: teamChat, kind: .team(teamID: teamID), title: "QA Team", createdAt: date, updatedAt: date),
                selectConversation: false)
        }
        func target() throws -> ClaudeConnectionTarget {
            try ClaudeConnectionTarget(executableURL: URL(fileURLWithPath: "/fixture/claude"),
                expectedExecutableSHA256: String(repeating: "a", count: 64),
                profileURL: URL(fileURLWithPath: "/fixture/HighChurn.noindex/CLIProfile"),
                workingDirectoryURL: URL(fileURLWithPath: "/fixture/HighChurn.noindex/Work"),
                temporaryDirectoryURL: URL(fileURLWithPath: "/fixture/HighChurn.noindex/Temp"),
                homeDirectoryURL: URL(fileURLWithPath: "/fixture"))
        }
        fileprivate func service(_ store: SQLiteStore, runner: TeamReplyRunner, teams: Bool = true, readContext: Bool = false,
                                 sessions: Bool = false) throws -> OfficialClaudeTextReplyService {
            let assembler = readContext ? ClaudeContextAssemblyService { _, _ in "" } : nil
            return OfficialClaudeTextReplyService(repository: store, teammates: store, conversations: store, messages: store,
                preparer: TeamReplyPreparer(target: try target()), runner: runner, appOwnerID: appOwner,
                contextReader: readContext ? store : nil, contextAssembler: assembler, teams: teams ? store : nil,
                sessions: sessions ? store : nil, resumesSessions: sessions, sessionTranscriptExists: { _, _ in true })
        }
        func submission(to teammateID: TeammateID, text: String) -> ClaudeTextTurnSubmission {
            ClaudeTextTurnSubmission(conversationID: teamChat, teammateID: teammateID, userMessageID: MessageID(UUID()), text: text)
        }
    }

    @Test("Unmentioned text is answered by the lead with a team-aware prompt and an attributed reply")
    func leadAnswersUnmentionedText() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = TeamReplyRunner()
        let result = try await f.service(store, runner: runner).sendText(f.submission(to: f.mira, text: "Summarise the plan.")) { _ in }
        #expect(result.outcome == .completed)
        let request = try #require(await runner.requests.first)
        #expect(request.systemPrompt.contains("You are Mira"))
        #expect(request.systemPrompt.contains("Team conversation: QA Team"))
        #expect(request.systemPrompt.contains("Ada (Source verifier)"))
        #expect(request.systemPrompt.contains("Mira (Research lead), lead"))
        #expect(request.systemPrompt.contains("you answer as the lead"))
        #expect(request.systemPrompt.contains("Reply as yourself only"))
        expectTeammateHouseStyle(request.systemPrompt)
        let reply = try #require(result.savedReplyMessage)
        #expect(reply.author == .teammate(f.mira))
        #expect(reply.conversationID == f.teamChat)
    }

    @Test("A team turn never resumes or keeps a session: its team and handoff paragraphs are that turn's alone")
    func teamTurnsKeepNoSession() async throws {
        // The CLI keeps the first turn's prompt for the whole session
        // (2.1.278), so a lead's delegation fence and the results it
        // is handed back would be frozen at the first turn, or never arrive.
        let f = try Fixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = TeamReplyRunner()
        for text in ["Summarise the plan.", "And the risks?"] {
            let result = try await f.service(store, runner: runner, readContext: true, sessions: true)
                .sendText(f.submission(to: f.mira, text: text)) { _ in }
            #expect(result.outcome == .completed)
        }
        let requests = await runner.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { !$0.resumesSession && !$0.persistsSession })
        #expect(try await store.storedClaudeSession(conversationID: f.teamChat, teammateID: f.mira) == nil)
        #expect(requests.last?.text.contains("Summarise the plan.") == true)
    }

    @Test("An @mention is answered by that member and the prompt says so")
    func mentionedMemberAnswers() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = TeamReplyRunner()
        let result = try await f.service(store, runner: runner).sendText(f.submission(to: f.ada, text: "@Ada check the sources")) { _ in }
        #expect(result.outcome == .completed)
        let request = try #require(await runner.requests.first)
        #expect(request.systemPrompt.contains("You are Ada"))
        #expect(request.systemPrompt.contains("addressed you by name with @Ada"))
        expectTeammateHouseStyle(request.systemPrompt)
        #expect(try #require(result.savedReplyMessage).author == .teammate(f.ada))
    }

    @Test("A non-member, a recipient that does not match the routing, or no team repository is refused before any write",
          arguments: ["nonMember", "routeMismatch", "noTeams"])
    func refusals(_ mode: String) async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = TeamReplyRunner()
        let service = try f.service(store, runner: runner, teams: mode != "noTeams")
        // "noTeams" submits to the lead, whose route is valid, so the missing
        // repository is the only reason the send can be refused.
        let submission: ClaudeTextTurnSubmission
        switch mode {
        case "nonMember": submission = f.submission(to: f.zed, text: "hello")
        case "noTeams": submission = f.submission(to: f.mira, text: "hello with no mention")
        default: submission = f.submission(to: f.ada, text: "hello with no mention")
        }
        let result = await service.sendText(submission) { _ in }
        #expect(result.outcome == .failed(.unavailable))
        #expect(result.savedUserMessage == nil)
        #expect(await runner.requests.isEmpty)
        #expect(try await store.page(conversationID: f.teamChat, request: PageRequest(limit: 5)).elements.isEmpty)
    }

    /// A hidden bot
    /// keeps its seat and shows in its teams, whether it is named or leads.
    @Test("A hidden member answers its @mention and a hidden lead answers unmentioned text", arguments: ["member", "lead"])
    func hiddenBotAnswersInItsTeam(_ who: String) async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let hidden = who == "lead" ? f.mira : f.ada
        _ = try await store.execute(sql: "UPDATE teammates SET is_hidden=1 WHERE id=?;", bindings: [.text(hidden.persistedValue)])
        let runner = TeamReplyRunner()
        let text = who == "lead" ? "Summarise the plan." : "@Ada check the sources"
        let result = try await f.service(store, runner: runner, readContext: true).sendText(f.submission(to: hidden, text: text)) { _ in }
        #expect(result.outcome == .completed)
        #expect(await runner.requests.count == 1)
        #expect(try #require(result.savedReplyMessage).author == .teammate(hidden))
    }

    @Test("The provenance record of a team reply names the member whose run produced it")
    func provenanceNamesTheAnsweringMember() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = TeamReplyRunner()
        let result = try await f.service(store, runner: runner)
            .sendText(f.submission(to: f.ada, text: "@Ada check the sources")) { _ in }
        #expect(result.outcome == .completed)
        let user = try #require(result.savedUserMessage), reply = try #require(result.savedReplyMessage)
        let provenance = try await store.textTurnProvenance(conversationID: f.teamChat, messageIDs: [user.id, reply.id])
        #expect(provenance.count == 1)
        #expect(provenance.first?.replyMessageID == reply.id)
        // Ada, not the lead and not a conversation-wide default: the run's bot.
        // A memory-qualified reply is stored with no author teammate, so this
        // record is the only place a team transcript can read it from.
        #expect(provenance.first?.teammateID == f.ada)
    }

    @Test("With read context wired, a member's turn passes the store's authority checks and its profile follows the house voice")
    func readContextAcceptsAMember() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store, leadInstructions: "Answer with one heading per source and the full list of links.")
        let runner = TeamReplyRunner()
        let result = try await f.service(store, runner: runner, readContext: true).sendText(f.submission(to: f.mira, text: "Plan?")) { _ in }
        #expect(result.outcome == .completed)
        #expect(await runner.requests.count == 1)
        let request = try #require(await runner.requests.first)
        // The assembler builds its own profile prompt and never calls the
        // service's profile-only seam, and production wires the assembler. A
        // house style that only reached the seam would never reach a user.
        #expect(request.systemPrompt.contains("The complete user-approved profile follows"))
        expectTeammateHouseStyle(request.systemPrompt)
        #expect(request.systemPrompt.contains("Team conversation: QA Team"))
        // Production only ever builds this prompt, so the order is pinned here
        // and not only on the seam: the voice comes first and the profile's
        // detailed instructions come after it, so a profile that wants
        // headings has the last word.
        let style = try #require(request.systemPrompt.range(of: "How you talk:"))
        let label = try #require(request.systemPrompt.range(of: "Detailed instructions:"))
        let own = try #require(request.systemPrompt.range(of: "Answer with one heading per source and the full list of links."))
        #expect(style.lowerBound < label.lowerBound && label.lowerBound < own.lowerBound)
    }
}
