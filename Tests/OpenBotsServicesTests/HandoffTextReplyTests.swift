import CryptoKit
import Foundation
import OpenBotsContent
import OpenBotsDomain
@testable import OpenBotsPersistence
import OpenBotsRuntime
@testable import OpenBotsServices
import Testing

/// Consecutive turns return different texts, so one fixture can drive the
/// lead's staging turn, the member's leg and the lead's fan-in turn. Each reply
/// is a list of cumulative snapshots, so a turn can stream in pieces.
private actor HandoffReplyRunner: ClaudeTextOnlyRunning {
    private(set) var requests: [ClaudeTextOnlyRequest] = []
    private var replies: [[String]]
    private let failAfterFirst: Bool
    /// The one run that fails after a partial, so a lead's report turn can
    /// break while the member's leg before it completes.
    private let failOnRun: Int?
    private let stallFromRun: Int?
    /// What the bot does on the Mac during a given run (1-based), before it
    /// answers: a member leaving a file in its Outbox, for instance.
    private let onRun: (@Sendable (Int) throws -> Void)?
    private var runs = 0
    /// The runs, counted from one, whose bot reads something private of the user's
    /// through its first reader connector before it answers.
    private let readsOnRuns: Set<Int>
    /// The runs whose bot asks for one web fetch before it answers, and
    /// whether each run was given a channel to ask on at all.
    private let fetchesOnRuns: Set<Int>
    private(set) var controlled: [Bool] = []
    private var control: ClaudeTextTurnControl?

    init(replies: [[String]], failAfterFirst: Bool = false, failOnRun: Int? = nil, stallFromRun: Int? = nil,
         onRun: (@Sendable (Int) throws -> Void)? = nil, readsOnRuns: Set<Int> = [], fetchesOnRuns: Set<Int> = []) {
        self.readsOnRuns = readsOnRuns
        self.fetchesOnRuns = fetchesOnRuns
        self.replies = replies
        self.failAfterFirst = failAfterFirst
        self.failOnRun = failOnRun
        self.stallFromRun = stallFromRun
        self.onRun = onRun
    }

    init(replies: [String], failAfterFirst: Bool = false, failOnRun: Int? = nil, stallFromRun: Int? = nil,
         onRun: (@Sendable (Int) throws -> Void)? = nil, readsOnRuns: Set<Int> = [], fetchesOnRuns: Set<Int> = []) {
        self.init(replies: replies.map { [$0] }, failAfterFirst: failAfterFirst, failOnRun: failOnRun,
                  stallFromRun: stallFromRun, onRun: onRun, readsOnRuns: readsOnRuns, fetchesOnRuns: fetchesOnRuns)
    }

    func run(request: ClaudeTextOnlyRequest, control: ClaudeTextTurnControl?,
             onEvent: @escaping @Sendable (ClaudeTextOnlyEvent) async -> Void) async -> ClaudeTextOnlyResult {
        self.control = control
        defer { self.control = nil }
        controlled.append(control != nil)
        return await run(request: request, onEvent: onEvent)
    }

    /// One web fetch, asked on the turn's channel when the turn launched with
    /// the web left to ask; a turn that pre-allowed it never asks the app.
    private func fetch(_ request: ClaudeTextOnlyRequest,
                       onEvent: @escaping @Sendable (ClaudeTextOnlyEvent) async -> Void) async {
        guard let control, !request.preApprovedToolNames.contains("WebFetch") else { return }
        let input = Data(#"{"url":"https://example.com/a","prompt":"p"}"#.utf8)
        await onEvent(.toolUse(ClaudeTextToolUse(id: "toolu_fetch", toolName: "WebFetch", inputJSON: input)))
        let asked = ClaudeTextPermissionRequest(requestID: "req-fetch", toolUseID: "toolu_fetch", toolName: "WebFetch", inputJSON: input)
        control.register(asked)
        await onEvent(.permissionRequested(asked))
        for _ in 0..<100 {
            if !control.takePending().isEmpty { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        await onEvent(.toolFinished(toolUseID: "toolu_fetch", failed: true))
    }

    /// One read through the turn's first reader connector, asked and let through.
    private func readPrivately(_ request: ClaudeTextOnlyRequest,
                               onEvent: @escaping @Sendable (ClaudeTextOnlyEvent) async -> Void) async {
        guard let control, let server = request.connectorAccess?.servers.first(where: { $0.role.readsPrivately }) else { return }
        let name = server.toolNamespace + "search_contacts"
        let input = Data(#"{"query":"Charles"}"#.utf8)
        await onEvent(.toolUse(ClaudeTextToolUse(id: "toolu_read", toolName: name, inputJSON: input)))
        let asked = ClaudeTextPermissionRequest(requestID: "req-read", toolUseID: "toolu_read", toolName: name, inputJSON: input)
        control.register(asked)
        await onEvent(.permissionRequested(asked))
        for _ in 0..<800 {
            if !control.takePending().isEmpty { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        await onEvent(.toolFinished(toolUseID: "toolu_read", failed: false))
    }

    func run(request: ClaudeTextOnlyRequest,
             onEvent: @escaping @Sendable (ClaudeTextOnlyEvent) async -> Void) async -> ClaudeTextOnlyResult {
        requests.append(request)
        runs += 1
        let snapshots = replies.isEmpty ? [] : replies.removeFirst()
        await onEvent(.initialized(sessionID: request.sessionID, actualModel: request.expectedResolvedModel))
        await onEvent(.inputSubmitted(messageID: request.messageID))
        await onEvent(.inputAcknowledged(messageID: request.messageID))
        if failAfterFirst && runs > 1 || failOnRun == runs {
            await onEvent(.textSnapshot("partial"))
            return .failed(.processFailed)
        }
        if let stallFromRun, runs >= stallFromRun {
            await onEvent(.textSnapshot("partial"))
            // Bounded, so a regression fails the test instead of hanging it.
            var spins = 0
            while !Task.isCancelled, spins < 1_000_000 {
                await Task.yield()
                spins += 1
            }
            return .cancelled
        }
        if let onRun { try? onRun(runs) }
        if readsOnRuns.contains(runs) { await readPrivately(request, onEvent: onEvent) }
        if fetchesOnRuns.contains(runs) { await fetch(request, onEvent: onEvent) }
        for snapshot in snapshots { await onEvent(.textSnapshot(snapshot)) }
        return .success(ClaudeTextOnlyReply(sessionID: request.sessionID,
            actualModel: request.expectedResolvedModel, text: snapshots.last ?? ""))
    }
}

private actor HandoffReplyPreparer: ClaudeTextLaunchPreparing {
    let target: ClaudeConnectionTarget
    private(set) var calls = 0
    private var refusal: ClaudeTextTurnProblem?
    init(target: ClaudeConnectionTarget) { self.target = target }
    /// Readiness the caller can withdraw between turns, the way an uninstalled
    /// or unsubscribed CLI does between the lead's reply and the user's click.
    func refuse(_ problem: ClaudeTextTurnProblem?) { refusal = problem }
    func prepareTextLaunch(runID: UUID) async -> ClaudeTextLaunchPreparation {
        calls += 1
        if let refusal { return .refused(refusal) }
        return .ready(target)
    }
    func prepareTextLaunch(runID: UUID, model: String) async -> ClaudeTextLaunchPreparation { await prepareTextLaunch(runID: runID) }
    func prepareTextLaunch(runID: UUID, selection: ClaudeExecutionSelection) async -> ClaudeTextLaunchPreparation { await prepareTextLaunch(runID: runID) }
}

/// The control database with a handoff insert that fails a stated number of
/// times before forwarding, so a delegation that cannot be staged can be shown.
private actor HandoffInsertFailingRepository: HandoffRepository {
    private let inner: any HandoffRepository
    private var remainingFailures: Int
    private(set) var inserts = 0
    init(_ inner: any HandoffRepository, failures: Int) { self.inner = inner; remainingFailures = failures }
    func insert(_ record: HandoffRecord) async throws {
        inserts += 1
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw RepositoryError.unavailable(reason: "handoff insert refused")
        }
        try await inner.insert(record)
    }
    func update(_ record: HandoffRecord, expectedState: HandoffState) async throws {
        try await inner.update(record, expectedState: expectedState)
    }
    func record(id: HandoffID) async throws -> HandoffRecord? { try await inner.record(id: id) }
    func records(conversationID: ConversationID) async throws -> [HandoffRecord] {
        try await inner.records(conversationID: conversationID)
    }
}

/// A work grant for one bot only: the member has a desk, the lead has none.
private struct HandoffWorkAccess: ClaudeTextReplyWebAccessResolving {
    let teammateID: TeammateID
    let access: ClaudeTextWorkAccess
    func allowedTextReplyTools(teammateID: TeammateID) async -> Set<ClaudeTextOnlyTool> { [] }
    func webAccessChanges() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    func workAccess(teammateID: TeammateID) async -> ClaudeTextWorkAccess? { teammateID == self.teammateID ? access : nil }
}

/// Both hire switches on for the named bots only.
private struct HandoffHireAccess: ClaudeTextReplyWebAccessResolving {
    let hirers: Set<TeammateID>
    func allowedTextReplyTools(teammateID: TeammateID) async -> Set<ClaudeTextOnlyTool> { [] }
    func webAccessChanges() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    func hireGranted(teammateID: TeammateID) async -> Bool { hirers.contains(teammateID) }
}

/// A hiring service no call reaches in these turns: what a turn is told is the subject.
/// Web for every bot; a Contacts connector for the readers.
private struct HandoffPrivateReadAccess: ClaudeTextReplyWebAccessResolving {
    let readers: Set<TeammateID>
    static let serverName = "openbots_" + String(repeating: "636f6e74", count: 8)
    func allowedTextReplyTools(teammateID: TeammateID) async -> Set<ClaudeTextOnlyTool> { [.webFetch, .webSearch] }
    func webAccessChanges() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    func grantedConnectorNames(teammateID: TeammateID) async -> Set<String> {
        readers.contains(teammateID) ? [Self.serverName] : []
    }
    func connectorAccess(teammateID: TeammateID, runID: UUID) async -> ClaudeTextConnectorAccess? {
        guard readers.contains(teammateID) else { return nil }
        return try? ClaudeTextConnectorAccess(servers: [try ClaudeTextConnectorServer(name: Self.serverName,
            role: .appleContactsRead, executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/node"),
            entryPointURL: URL(fileURLWithPath: "/private/tmp/contacts.js"), options: [], environment: [:])])
    }
}

private struct HandoffNoHiring: TeammateHiring {
    func hire(_ submission: TeammateHireSubmission) async -> TeammateHireOutcome { .refused(.notCreated) }
    func finishReply(_ replyID: UUID) async -> [TeammateHireOutcome] { [] }
}

@Suite("Handoffs through the text reply service")
struct HandoffTextReplyTests {
    static let fence = """
    ```handoff
    {"to": "Ada", "goal": "Write a haiku about teamwork", "constraints": ["Three lines"], "inputs": [], "requestedOutput": "The haiku only", "exclusions": [], "boundary": "Stop after one haiku"}
    ```
    """

    struct Fixture {
        let directory: URL
        let receipt: ProtectionDecisionReceipt
        let date = Date(timeIntervalSince1970: 4_000)
        let appOwner = UUID()
        let ada = TeammateID(UUID()), mira = TeammateID(UUID()), zed = TeammateID(UUID())
        let teamID = TeamID(UUID()), teamChat = ConversationID(UUID())
        init() throws {
            directory = URL(fileURLWithPath: "/private/tmp/OpenBotsNextHandoffTextReply-\(UUID()).noindex", isDirectory: true)
            receipt = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
        func open() throws -> SQLiteStore {
            try SQLiteStore(configuration: SQLiteStoreConfiguration(fileURL: directory.appendingPathComponent("control.sqlite"),
                protection: .ordinarySQLite(decision: receipt)))
        }
        func seed(_ store: SQLiteStore, includeZed: Bool = false) async throws {
            for (id, name, role) in [(ada, "Ada", "Source verifier"), (mira, "Mira", "Research lead"), (zed, "Zed", "Outsider")] {
                let bot = try Teammate(id: id, profile: TeammateProfile(displayName: name, role: role),
                    appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 6, silhouette: "round",
                        paletteToken: "sky", eyeDialect: "bright", nonColorIdentityCue: "single crest", accessibleIdentityDescription: "Round creature with a crest"),
                    createdAt: date, updatedAt: date)
                try await store.provisionDirectChat(teammate: bot,
                    conversation: Conversation(id: ConversationID(UUID()), kind: .direct(teammateID: id), createdAt: date, updatedAt: date),
                    fixtureGreeting: nil, selectConversation: false)
            }
            try await store.provisionTeam(Team(id: teamID, name: "QA Team", leadID: mira, memberIDs: includeZed ? [ada, mira, zed] : [ada, mira], createdAt: date, updatedAt: date),
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
        fileprivate func service(_ store: SQLiteStore, runner: HandoffReplyRunner,
                                 teams: Bool = true, handoffs: Bool = true,
                                 preparer: HandoffReplyPreparer? = nil,
                                 handoffRepository: (any HandoffRepository)? = nil,
                                 webAccess: (any ClaudeTextReplyWebAccessResolving)? = nil,
                                 deliverables: (any ProducedFileAttaching)? = nil,
                                 hiring: (any TeammateHiring)? = nil,
                                 clock: any OpenBotsClock = SystemClock(),
                                 heartbeat: Duration = .seconds(60)) throws -> OfficialClaudeTextReplyService {
            OfficialClaudeTextReplyService(repository: store, teammates: store, conversations: store, messages: store,
                preparer: try preparer ?? HandoffReplyPreparer(target: target()), runner: runner, appOwnerID: appOwner,
                clock: clock,
                teams: teams ? store : nil, handoffs: handoffs ? (handoffRepository ?? store) : nil,
                webAccess: webAccess, deliverables: deliverables, hiring: hiring, missingFileHeartbeat: heartbeat)
        }
        /// The app's attachment service over this store, with an importer that
        /// only measures the file: the bytes never move, the record does.
        func attachments(_ store: SQLiteStore) -> ConversationAttachmentService {
            ConversationAttachmentService(repository: store, messages: store,
                importer: { url, id in
                    let data = try Data(contentsOf: url)
                    return try StoredAttachmentContent(id: id, byteCount: Int64(data.count),
                        sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                        typeIdentifier: "net.daringfireball.markdown", displayName: url.lastPathComponent)
                },
                verifier: { _ in }, location: { _ in throw ConversationAttachmentError.unavailable })
        }
        func submission(to teammateID: TeammateID, text: String) -> ClaudeTextTurnSubmission {
            ClaudeTextTurnSubmission(conversationID: teamChat, teammateID: teammateID, userMessageID: MessageID(UUID()), text: text)
        }
    }

    @Test("The lead's fence is stripped from the saved reply and staged as a handoff anchored to that reply")
    func leadStagesAHandoff() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = HandoffReplyRunner(replies: ["I'll have Ada write it.\n\n" + Self.fence])
        let service = try f.service(store, runner: runner)
        let result = await service.sendText(f.submission(to: f.mira, text: "Can someone write a haiku?")) { _ in }
        #expect(result.outcome == .completed)
        let request = try #require(await runner.requests.first)
        #expect(request.systemPrompt.contains("Delegating: you may hand one task"))
        #expect(request.systemPrompt.contains("\"Ada\""))
        // The roster is the team's members; Zed exists but is not in the team.
        #expect(!request.systemPrompt.contains("Zed"))
        let reply = try #require(result.savedReplyMessage)
        // Only the fence region is deleted, so the blank line the lead left
        // before it stays exactly where the lead put it.
        #expect(reply.parts.first?.content == .text("I'll have Ada write it.\n\n"))
        let records = try await store.records(conversationID: f.teamChat)
        let record = try #require(records.first)
        #expect(records.count == 1)
        #expect(record.state == .staged && record.senderID == f.mira && record.receiverID == f.ada)
        #expect(record.sourceMessageID == reply.id)
        #expect(record.brief.goal == "Write a haiku about teamwork")
    }

    @Test("A fence that does not parse is kept verbatim and stages nothing")
    func malformedFenceIsKept() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let text = "Trying.\n\n```handoff\n{\"to\": \"Nobody\", \"goal\": \"x\", \"requestedOutput\": \"y\", \"boundary\": \"z\"}\n```"
        let runner = HandoffReplyRunner(replies: [text])
        let service = try f.service(store, runner: runner)
        let result = await service.sendText(f.submission(to: f.mira, text: "Delegate")) { _ in }
        let reply = try #require(result.savedReplyMessage)
        #expect(reply.parts.first?.content == .text(text))
        let records = try await store.records(conversationID: f.teamChat)
        #expect(records.isEmpty)
    }

    @Test("Sending the leg runs the member on the lead-authored brief, records the result, and the lead's next turn references it")
    func legRunsAndReturns() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = HandoffReplyRunner(replies: ["Ada, over to you.\n\n" + Self.fence,
                                                 "Silent hands align\none river from many streams\nthe work moves as one",
                                                 "Ada wrote: silent hands align."])
        let service = try f.service(store, runner: runner)
        _ = await service.sendText(f.submission(to: f.mira, text: "Haiku please")) { _ in }
        let staged = try #require(try await store.records(conversationID: f.teamChat).first)
        let recorder = ProgressRecorder()
        let result = await service.sendHandoffLeg(HandoffLegSubmission(handoffID: staged.id)) { await recorder.append($0) }
        #expect(result.outcome == .completed)
        let brief = try #require(result.savedUserMessage)
        #expect(brief.author == .teammate(f.mira) && brief.conversationID == f.teamChat)
        let sender = try #require(try await store.teammate(id: f.mira))
        let receiver = try #require(try await store.teammate(id: f.ada))
        #expect(brief.parts.first?.content == .text(HandoffFence.renderBrief(staged.brief, sender: sender, receiver: receiver)))
        let reply = try #require(result.savedReplyMessage)
        #expect(reply.author == .teammate(f.ada))
        let legRequest = try #require(await runner.requests.dropFirst().first)
        #expect(legRequest.systemPrompt.contains("You are Ada"))
        #expect(legRequest.systemPrompt.contains("Mira, the lead, handed you this brief"))
        #expect(legRequest.systemPrompt.contains("Your answer goes back to Mira, who compiles it for the user"))
        #expect(legRequest.systemPrompt.contains("no preface, no closing offer"))
        expectTeammateHouseStyle(legRequest.systemPrompt)
        #expect(!legRequest.systemPrompt.contains("Delegating:"))
        // The callback carries the message as saved, before the turn settles it
        // to `completed`, so the brief is matched by identity and content.
        let progress = await recorder.events
        #expect(progress.contains {
            guard case .userMessageSaved(let saved) = $0 else { return false }
            return saved.id == brief.id && saved.author == brief.author
                && saved.parts.map(\.content) == brief.parts.map(\.content)
        })
        let done = try #require(try await store.record(id: staged.id))
        #expect(done.state == .succeeded)
        #expect(done.briefMessageID == brief.id && done.replyMessageID == reply.id && done.runID != nil)
        #expect(done.handoff.resultSummary?.hasPrefix("Silent hands align") == true)
        // The lead's next turn carries the result and marks the handoff returned.
        _ = await service.sendText(f.submission(to: f.mira, text: "So what did Ada say?")) { _ in }
        let leadRequest = try #require(await runner.requests.last)
        #expect(leadRequest.systemPrompt.contains("Results returned from members"))
        #expect(leadRequest.systemPrompt.contains("Silent hands align"))
        let returned = try await store.record(id: staged.id)
        #expect(returned?.state == .returnedToOrigin)
        let page = try await store.page(conversationID: f.teamChat, request: PageRequest(limit: 10)).elements
        #expect(page.map(\.author) == [.user, .teammate(f.mira), .teammate(f.mira), .teammate(f.ada), .user, .teammate(f.mira)])
        // The brief and the member's reply are the work channel.
        #expect(page.map(\.outputClass) == [.conversation, .conversation, .workAudit, .workAudit, .conversation, .conversation])
    }

    // The fence a private read closes follows the words to a teammate and back.
    @Test("A lead that read the user's contacts hands off: the member's leg asks before every web call; one that read nothing does not fence it",
          arguments: [true, false])
    func theFenceTravelsWithTheBrief(_ leadReads: Bool) async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = HandoffReplyRunner(replies: ["Ada, over to you.\n\n" + Self.fence, "Silent hands align"],
                                        readsOnRuns: leadReads ? [1] : [], fetchesOnRuns: [2])
        let service = try f.service(store, runner: runner, webAccess: HandoffPrivateReadAccess(readers: [f.mira]))
        #expect(await service.sendText(f.submission(to: f.mira, text: "Haiku please")) { _ in }.outcome == .completed)
        let staged = try #require(try await store.records(conversationID: f.teamChat).first)
        let cards = ProgressRecorder()
        #expect(await service.sendHandoffLeg(HandoffLegSubmission(handoffID: staged.id)) { await cards.append($0) }.outcome == .completed)
        let leg = try #require(await runner.requests.dropFirst().first)
        #expect(leg.connectorAccess == nil && leg.asksBeforeWeb == leadReads, "\(leg.asksBeforeWeb)")
        #expect(leg.preApprovedToolNames.contains("WebFetch") == !leadReads)
        // What the CLI is actually launched with (a member's leg must not have
        // the web pre-allowed in its settings and no channel).
        #expect(ClaudeTextOnlyCommandBuilder.arguments(for: leg).contains("--permission-prompt-tool") == leadReads)
        #expect(await runner.controlled.dropFirst().first == leadReads)
        // And the fetch the member asks for goes up on a card naming who read what.
        let shown = await cards.events.compactMap { event -> ClaudeTextApproval? in
            if case .approvalRequired(let card) = event { return card }; return nil
        }
        #expect(shown.count == (leadReads ? 1 : 0), "\(shown)")
        if leadReads { #expect(shown.first?.detail.contains("Mira read your contacts earlier in this chat and handed the work on") == true, "\(shown)") }
    }

    @Test("A member that read the user's contacts on its leg fences the lead's report turn")
    func theFenceComesBackWithTheReport() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = HandoffReplyRunner(replies: ["Ada, over to you.\n\n" + Self.fence, "Silent hands align", "Here it is."],
                                        readsOnRuns: [2])
        let service = try f.service(store, runner: runner, webAccess: HandoffPrivateReadAccess(readers: [f.ada]))
        _ = await service.sendText(f.submission(to: f.mira, text: "Haiku please")) { _ in }
        let staged = try #require(try await store.records(conversationID: f.teamChat).first)
        #expect(await service.sendHandoffLeg(HandoffLegSubmission(handoffID: staged.id)) { _ in }.outcome == .completed)
        #expect(await runner.requests.first?.asksBeforeWeb == false)
        #expect(await service.sendHandoffReport(HandoffReportSubmission(handoffID: staged.id)) { _ in }.outcome == .completed)
        let report = try #require(await runner.requests.last)
        #expect(report.connectorAccess == nil && report.asksBeforeWeb, "the lead compiles words the member read")
    }

    // A report that never ran leaves the leg
    // succeeded, and the lead's next user turn quotes the member's words.
    @Test("A lead's own turn that gets a member's results back is fenced by what the member read, or when the chain is unknown after a relaunch",
          arguments: [false, true])
    func returnedResultsCarryTheFence(_ relaunched: Bool) async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = HandoffReplyRunner(replies: ["Ada, over to you.\n\n" + Self.fence, "Silent hands align", "Ada wrote it."],
                                        readsOnRuns: relaunched ? [] : [2])
        let access = HandoffPrivateReadAccess(readers: relaunched ? [] : [f.ada])
        let service = try f.service(store, runner: runner, webAccess: access)
        _ = await service.sendText(f.submission(to: f.mira, text: "Haiku please")) { _ in }
        let staged = try #require(try await store.records(conversationID: f.teamChat).first)
        #expect(await service.sendHandoffLeg(HandoffLegSubmission(handoffID: staged.id)) { _ in }.outcome == .completed)
        // No report ran: the user's next message to the lead gets the result back.
        let lead = relaunched ? try f.service(store, runner: runner, webAccess: access) : service
        #expect(await lead.sendText(f.submission(to: f.mira, text: "So what did Ada say?")) { _ in }.outcome == .completed)
        let request = try #require(await runner.requests.last)
        #expect(request.systemPrompt.contains("Results returned from members"))
        #expect(request.asksBeforeWeb, "the lead's turn quotes words the member read")
    }

    @Test("A leg from a brief this app run never saw staged is fenced: what the lead read before the relaunch is not known")
    func aLegStagedBeforeARelaunchIsFenced() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = HandoffReplyRunner(replies: ["Ada, over to you.\n\n" + Self.fence, "Silent hands align"])
        let access = HandoffPrivateReadAccess(readers: [])
        _ = await (try f.service(store, runner: runner, webAccess: access)).sendText(f.submission(to: f.mira, text: "Haiku please")) { _ in }
        let staged = try #require(try await store.records(conversationID: f.teamChat).first)
        let relaunched = try f.service(store, runner: runner, webAccess: access)
        #expect(await relaunched.sendHandoffLeg(HandoffLegSubmission(handoffID: staged.id)) { _ in }.outcome == .completed)
        #expect(await runner.requests.last?.asksBeforeWeb == true)
    }

    @Test("A member's web card names who read what and handed the work on")
    func aCarriedFenceNamesWhoRead() {
        let question = ClaudeTextPermissionRequest(requestID: "r", toolUseID: "t", toolName: "WebFetch",
            inputJSON: Data(#"{"url":"https://example.com/a","prompt":"p"}"#.utf8))
        let decision = OfficialClaudeTextReplyService.webDecision(question, botName: "Ada", afterTexts: false,
            afterOther: "your contacts", readBy: "Mira")
        guard case .ask(let card) = decision else { Issue.record("\(decision)"); return }
        #expect(card.detail.contains("Mira read your contacts earlier in this chat and handed the work on"), "\(card.detail)")
    }

    @Test("The lead compiles a finished leg for the user: the report is the member's work-channel message, the answer is the lead's")
    func reportTurnCompilesForTheUser() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = HandoffReplyRunner(replies: ["Ada, over to you.\n\n" + Self.fence,
                                                 "Silent hands align\none river from many streams\nthe work moves as one",
                                                 "Here it is.\n\nSilent hands align, one river from many streams, the work moves as one."])
        let service = try f.service(store, runner: runner)
        _ = await service.sendText(f.submission(to: f.mira, text: "Haiku please")) { _ in }
        let staged = try #require(try await store.records(conversationID: f.teamChat).first)
        // Nothing to compile before the member answered.
        #expect(await service.sendHandoffReport(HandoffReportSubmission(handoffID: staged.id)) { _ in }.outcome == .failed(.unavailable))
        let leg = await service.sendHandoffLeg(HandoffLegSubmission(handoffID: staged.id)) { _ in }
        #expect(leg.outcome == .completed)
        let recorder = ProgressRecorder()
        let result = await service.sendHandoffReport(HandoffReportSubmission(handoffID: staged.id)) { await recorder.append($0) }
        #expect(result.outcome == .completed)
        let report = try #require(result.savedUserMessage)
        #expect(report.author == .teammate(f.ada) && report.outputClass == .workAudit)
        guard case .text(let reportText)? = report.parts.first?.content else { Issue.record("no report text"); return }
        #expect(reportText.hasPrefix("Ada reports back on \"Write a haiku about teamwork\":\n\nSilent hands align"))
        let answer = try #require(result.savedReplyMessage)
        #expect(answer.author == .teammate(f.mira) && answer.outputClass == .conversation)
        #expect(answer.parts.first?.content == .text("Here it is.\n\nSilent hands align, one river from many streams, the work moves as one."))
        let leadRequest = try #require(await runner.requests.last)
        #expect(leadRequest.text == reportText)
        #expect(leadRequest.systemPrompt.contains("Ada, a member of your team, has reported back on the brief you handed off"))
        #expect(leadRequest.text.contains("Original user request for this chain:\nHaiku please"))
        #expect(leadRequest.systemPrompt.contains("Delegating:"))
        #expect(try await store.record(id: staged.id)?.state == .returnedToOrigin)
        // Compiled once: the record is returned and a second report is refused.
        #expect(await service.sendHandoffReport(HandoffReportSubmission(handoffID: staged.id)) { _ in }.outcome == .failed(.unavailable))
        let page = try await store.page(conversationID: f.teamChat, request: PageRequest(limit: 10)).elements
        #expect(page.map(\.outputClass) == [.conversation, .conversation, .workAudit, .workAudit, .workAudit, .conversation])
        let progress = await recorder.events
        #expect(progress.contains { if case .assistantMessageSaved(let saved) = $0 { return saved.id == answer.id } else { return false } })
    }

    @Test("Two members answer sequentially; full same-chain reports and both files reach one final answer")
    func twoMemberChainCompilesOnce() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store, includeZed: true)
        let firstReport = String(repeating: "Verified detail. ", count: 200) + "FINAL_FACT_FROM_ADA"
        let nextFence = Self.fence.replacingOccurrences(of: "\"Ada\"", with: "\"Zed\"")
        let runner = HandoffReplyRunner(replies: ["I'll ask both.\n\n" + Self.fence,
            firstReport, "Now Zed can check it.\n\n" + nextFence, "ZED_FINDING", "One compiled answer from both members."])
        let attachments = f.attachments(store)
        let service = try f.service(store, runner: runner, deliverables: attachments)
        let submission = f.submission(to: f.mira, text: "Ask Ada, then Zed; combine their findings and files.")
        #expect(await service.sendText(submission) { _ in }.outcome == .completed)
        let first = try #require(try await store.records(conversationID: f.teamChat).first)
        let firstLeg = await service.sendHandoffLeg(.init(handoffID: first.id)) { _ in }
        let firstReply = try #require(firstLeg.savedReplyMessage)
        let firstFile = f.directory.appending(path: "ada.md")
        try Data("Ada's file".utf8).write(to: firstFile)
        _ = await attachments.attachProducedFiles([firstFile], toReply: firstReply.id, conversationID: f.teamChat)
        // Another request's unfinished result is not this chain's to compile
        // or mark returned, even though its lead and room are the same.
        var unrelated = HandoffRecord(handoff: try Handoff(provenance: HandoffProvenance(handoffID: HandoffID(UUID()),
            legID: HandoffLegID(UUID()), originConversationID: f.teamChat, senderID: f.mira, receiverID: f.ada,
            createdAt: f.date), brief: first.brief), sourceMessageID: nil)
        try await store.insert(unrelated)
        try unrelated.apply(.accept(at: f.date))
        try await store.update(unrelated, expectedState: .staged)
        try unrelated.apply(.beginWork(at: f.date))
        try await store.update(unrelated, expectedState: .accepted)
        try unrelated.apply(.succeed(summary: "UNRELATED_CHAIN_RESULT", at: f.date))
        try await store.update(unrelated, expectedState: .working)
        let continuation = await service.sendHandoffReport(.init(handoffID: first.id)) { _ in }
        #expect(continuation.outcome == .completed)
        #expect(continuation.savedReplyMessage?.outputClass == .workAudit)
        #expect(try await store.record(id: first.id)?.state == .succeeded)
        let second = try #require(try await store.records(conversationID: f.teamChat).first { $0.parentHandoffID == first.id })
        #expect(second.chainID == first.id && second.hopCount == 2 && second.receiverID == f.zed)
        #expect(second.originalUserMessageID == submission.userMessageID)
        // The persisted predecessor cannot compile a second time, including
        // after a new service/store instance is created.
        let reopened = try f.open()
        let reloadedService = try f.service(reopened, runner: runner, deliverables: attachments)
        #expect(await reloadedService.sendHandoffReport(.init(handoffID: first.id)) { _ in }.outcome == .failed(.unavailable))
        let secondLeg = await reloadedService.sendHandoffLeg(.init(handoffID: second.id)) { _ in }
        let secondReply = try #require(secondLeg.savedReplyMessage)
        let secondFile = f.directory.appending(path: "zed.md")
        try Data("Zed's file".utf8).write(to: secondFile)
        _ = await attachments.attachProducedFiles([secondFile], toReply: secondReply.id, conversationID: f.teamChat)
        let final = await reloadedService.sendHandoffReport(.init(handoffID: second.id)) { _ in }
        #expect(final.outcome == .completed)
        let answer = try #require(final.savedReplyMessage)
        #expect(answer.outputClass == .conversation)
        #expect(answer.parts.filter { if case .attachment = $0.content { true } else { false } }.count == 2)
        let finalRequest = try #require(await runner.requests.last)
        #expect(finalRequest.text.contains("FINAL_FACT_FROM_ADA") && finalRequest.text.contains("ZED_FINDING"))
        #expect(finalRequest.text.contains(submission.text))
        #expect(!finalRequest.text.contains("UNRELATED_CHAIN_RESULT") && !finalRequest.systemPrompt.contains("UNRELATED_CHAIN_RESULT"))
        #expect(try await reopened.records(conversationID: f.teamChat).filter { $0.chainID == first.id }.allSatisfy { $0.state == .returnedToOrigin })
        #expect(try await reopened.record(id: unrelated.id)?.state == .succeeded)
        let transcript = try await reopened.page(conversationID: f.teamChat, request: PageRequest(limit: 30)).elements
        #expect(transcript.filter { $0.outputClass == .conversation && $0.author == .teammate(f.mira) }.count == 2)
        #expect(await runner.requests.count == 5)
    }

    /// A chain whose next leg ends needing recovery, declined by the user or
    /// its bot deleted, goes no further, so the
    /// member results it already holds come back on the lead's next turn
    /// instead of waiting on a leg that will never run.
    @Test("A chain whose next leg was declined, or whose bot was deleted, gives its earlier results back to the lead",
          arguments: ["declined", "bot-deleted"])
    func endedLegReleasesItsChain(_ how: String) async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store, includeZed: true)
        let nextFence = Self.fence.replacingOccurrences(of: "\"Ada\"", with: "\"Zed\"")
        let runner = HandoffReplyRunner(replies: ["I'll ask both.\n\n" + Self.fence, "ADA_FINDING",
            "Now Zed can check it.\n\n" + nextFence, "Ada found it."])
        let service = try f.service(store, runner: runner)
        #expect(await service.sendText(f.submission(to: f.mira, text: "Ask Ada, then Zed.")) { _ in }.outcome == .completed)
        let first = try #require(try await store.records(conversationID: f.teamChat).first)
        #expect(await service.sendHandoffLeg(.init(handoffID: first.id)) { _ in }.outcome == .completed)
        #expect(await service.sendHandoffReport(.init(handoffID: first.id)) { _ in }.outcome == .completed)
        let second = try #require(try await store.records(conversationID: f.teamChat).first { $0.parentHandoffID == first.id })
        #expect(second.state == .staged && second.receiverID == f.zed)
        if how == "declined" {
            _ = try await HandoffService(repository: store).decline(id: second.id)
        } else {
            let zed = try #require(try await store.teammate(id: f.zed))
            _ = try await store.deleteTeammate(id: f.zed, expectedProfileRevision: zed.profile.revision, now: Date())
        }
        #expect(try await store.record(id: second.id)?.handoff.recovery?.code == how)
        _ = await service.sendText(f.submission(to: f.mira, text: "What did Ada find?")) { _ in }
        let leadRequest = try #require(await runner.requests.last)
        #expect(leadRequest.systemPrompt.contains("Results returned from members"))
        #expect(leadRequest.systemPrompt.contains("ADA_FINDING"))
        #expect(try await store.record(id: first.id)?.state == .returnedToOrigin)
        #expect(try await store.record(id: second.id)?.state == .needsRecovery)
    }

    /// A report that staged the next leg and then
    /// failed leaves a staged leg in a chain that holds a leg needing
    /// recovery. Such a chain admits nothing new, so the staged leg can never
    /// run, and must not withhold the chain's results from the lead for ever.
    @Test("A chain holding a leg that needs recovery gives its results back even with a staged leg left in it, once")
    func deadChainWithAStagedLegReleasesItsResults() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store, includeZed: true)
        let nextFence = Self.fence.replacingOccurrences(of: "\"Ada\"", with: "\"Zed\"")
        let runner = HandoffReplyRunner(replies: ["I'll ask Ada.\n\n" + Self.fence, "ADA_FINDING",
            "Now Zed.\n\n" + nextFence, "ZED_FINDING", "Back to Ada.\n\n" + Self.fence,
            "Here is what they found.", "Nothing new."])
        let service = try f.service(store, runner: runner)
        #expect(await service.sendText(f.submission(to: f.mira, text: "Ask Ada, then Zed, then Ada.")) { _ in }.outcome == .completed)
        let first = try #require(try await store.records(conversationID: f.teamChat).first)
        #expect(await service.sendHandoffLeg(.init(handoffID: first.id)) { _ in }.outcome == .completed)
        #expect(await service.sendHandoffReport(.init(handoffID: first.id)) { _ in }.outcome == .completed)
        let second = try #require(try await store.records(conversationID: f.teamChat).first { $0.parentHandoffID == first.id })
        #expect(await service.sendHandoffLeg(.init(handoffID: second.id)) { _ in }.outcome == .completed)
        #expect(await service.sendHandoffReport(.init(handoffID: second.id)) { _ in }.outcome == .completed)
        let third = try #require(try await store.records(conversationID: f.teamChat).first { $0.parentHandoffID == second.id })
        #expect(third.state == .staged)
        // The report's save failed after it staged the third leg: its record
        // ends as the service ends it.
        var failed = try #require(try await store.record(id: second.id))
        try failed.apply(.requireRecovery(HandoffRecovery(code: "report-failed",
            userMessage: "The lead could not compile the member's answer. The lead can hand this off again.",
            isRecoverable: true, occurredAt: Date())))
        try await store.update(failed, expectedState: .succeeded)
        #expect(await service.sendHandoffLeg(.init(handoffID: third.id)) { _ in }.outcome == .failed(.unavailable))
        #expect(await service.sendText(f.submission(to: f.mira, text: "What did Ada find?")) { _ in }.outcome == .completed)
        let prompt = try #require(await runner.requests.last).systemPrompt
        #expect(prompt.contains("Results returned from members") && prompt.contains("ADA_FINDING"))
        #expect(try await store.record(id: first.id)?.state == .returnedToOrigin)
        #expect(await service.sendText(f.submission(to: f.mira, text: "Thanks.")) { _ in }.outcome == .completed)
        let after = try #require(await runner.requests.last).systemPrompt
        #expect(!after.contains("ADA_FINDING") && !after.contains("Results returned from members"))
    }

    /// A lead user turn takes in the results of every
    /// chain that ended, and carries their chips. Over one reply's limit the
    /// save failed, the returns were never marked, and every later user turn
    /// in the team failed the same way. Now the text comes whole, the chips
    /// that fit come with it, and the lead and the record say how many were
    /// left out and that they stay in the work record.
    @Test("A lead turn returning two ended chains of thirteen files each carries what fits and never fails")
    func endedChainsOverTheFileLimitStillReturn() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store, includeZed: true)
        let nextFence = Self.fence.replacingOccurrences(of: "\"Ada\"", with: "\"Zed\"")
        let runner = HandoffReplyRunner(replies: [
            "I'll ask Ada.\n\n" + Self.fence, "ADA_ONE", "Now Zed.\n\n" + nextFence,
            "Asking Ada again.\n\n" + Self.fence, "ADA_TWO", "Now Zed.\n\n" + nextFence,
            "Here is what Ada found.", "Nothing new."])
        let attachments = f.attachments(store)
        let service = try f.service(store, runner: runner, deliverables: attachments)
        var firstLegs: [HandoffRecord] = []
        for chain in 1...2 {
            #expect(await service.sendText(f.submission(to: f.mira, text: "Ask Ada, then Zed (\(chain)).")) { _ in }.outcome == .completed)
            let first = try #require(try await store.records(conversationID: f.teamChat)
                .first { $0.state == .staged && $0.receiverID == f.ada })
            let leg = await service.sendHandoffLeg(.init(handoffID: first.id)) { _ in }
            #expect(leg.outcome == .completed)
            let files = try (0..<13).map { index in
                let file = f.directory.appending(path: "chain\(chain)-\(index).md")
                try Data("chain \(chain) file \(index)".utf8).write(to: file)
                return file
            }
            let reply = try #require(leg.savedReplyMessage)
            #expect(await attachments.attachProducedFiles(files, toReply: reply.id, conversationID: f.teamChat).count == 13)
            #expect(await service.sendHandoffReport(.init(handoffID: first.id)) { _ in }.outcome == .completed)
            firstLegs.append(first)
        }
        // Both chains end on a declined second leg, only after both have begun,
        // so one lead turn has all twenty-six files to return.
        for record in try await store.records(conversationID: f.teamChat) where record.state == .staged {
            _ = try await HandoffService(repository: store).decline(id: record.id)
        }
        let progress = ProgressRecorder()
        let lead = await service.sendText(f.submission(to: f.mira, text: "What did Ada find?")) { await progress.append($0) }
        #expect(lead.outcome == .completed)
        let reply = try #require(lead.savedReplyMessage)
        #expect(reply.parts.filter { if case .attachment = $0.content { true } else { false } }.count == 24)
        let prompt = try #require(await runner.requests.last).systemPrompt
        #expect(prompt.contains("ADA_ONE") && prompt.contains("ADA_TWO"))
        #expect(prompt.contains("2 files from these results will not come with your reply"), "\(prompt.suffix(600))")
        #expect(prompt.contains("stays in the work record"), "\(prompt.suffix(600))")
        let lines = await progress.events.compactMap { if case .activity(let line) = $0 { line } else { nil } }
        #expect(lines.contains("Left 2 of the members' files off this reply, which holds at most 24; they stay in the work record."),
                "\(lines)")
        for first in firstLegs { #expect(try await store.record(id: first.id)?.state == .returnedToOrigin) }
        // The next turn is not stuck, and returns nothing twice.
        #expect(await service.sendText(f.submission(to: f.mira, text: "Thanks.")) { _ in }.outcome == .completed)
        let after = try #require(await runner.requests.last).systemPrompt
        #expect(!after.contains("ADA_ONE") && !after.contains("Results returned from members"))
    }

    @Test("A complete chain's files are carried atomically before its final answer is published",
          arguments: [(13, false), (1, true)])
    func chainFileCapacityOrWriteFailureNeedsRecovery(_ testCase: (filesPerMember: Int, failWrite: Bool)) async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store, includeZed: true)
        let nextFence = Self.fence.replacingOccurrences(of: "\"Ada\"", with: "\"Zed\"")
        let runner = HandoffReplyRunner(replies: ["Starting.\n\n" + Self.fence,
            "Ada's report", "Continuing.\n\n" + nextFence, "Zed's report", "All files are ready."])
        let attachments = f.attachments(store)
        let service = try f.service(store, runner: runner, deliverables: attachments)
        #expect(await service.sendText(f.submission(to: f.mira, text: "Ask Ada, then Zed for their files.")) { _ in }.outcome == .completed)
        let first = try #require(try await store.records(conversationID: f.teamChat).first)
        var memberReplies: [MessageID] = []
        var sourceAssets: [AttachmentAsset] = []
        var current = first
        for member in ["ada", "zed"] {
            let leg = await service.sendHandoffLeg(.init(handoffID: current.id)) { _ in }
            #expect(leg.outcome == .completed)
            let reply = try #require(leg.savedReplyMessage)
            memberReplies.append(reply.id)
            let files = try (0..<testCase.filesPerMember).map { index in
                let file = f.directory.appending(path: "\(member)-\(index).md")
                try Data("\(member)'s file \(index)".utf8).write(to: file)
                return file
            }
            let assets = await attachments.attachProducedFiles(files, toReply: reply.id, conversationID: f.teamChat)
            #expect(assets.count == testCase.filesPerMember)
            sourceAssets += assets
            if member == "ada" {
                let continuation = await service.sendHandoffReport(.init(handoffID: current.id)) { _ in }
                #expect(continuation.outcome == .completed && continuation.savedReplyMessage?.outputClass == .workAudit)
                current = try #require(try await store.records(conversationID: f.teamChat).first { $0.parentHandoffID == first.id })
            }
        }
        if testCase.failWrite {
            // The member chips already exist in real SQLite. Only the final
            // carry write fails, even though this small chain fits the limit.
            _ = try await store.execute(sql: """
                CREATE TRIGGER reject_carried_chips BEFORE INSERT ON message_parts
                WHEN NEW.kind='attachment' BEGIN SELECT RAISE(ABORT,'fixture carry failure'); END;
                """)
        }
        let final = await service.sendHandoffReport(.init(handoffID: current.id)) { _ in }
        #expect(final.outcome == .failed(.persistenceFailed))
        let reply = try #require(final.savedReplyMessage)
        #expect(reply.outputClass == .workAudit && reply.deliveryState == .failed)
        #expect(!reply.parts.contains { if case .attachment = $0.content { true } else { false } })
        let reopened = try f.open()
        let records = try await reopened.records(conversationID: f.teamChat)
        #expect(records.count == 2 && records.allSatisfy { $0.state != .returnedToOrigin })
        #expect(records.first { $0.id == current.id }?.state == .needsRecovery)
        #expect(records.first { $0.id == current.id }?.handoff.recovery?.code == "report-failed")
        #expect(try await reopened.runs(conversationID: f.teamChat, limit: 1).first?.state == .failed)
        for sourceID in memberReplies {
            let source = try #require(try await reopened.message(id: sourceID))
            #expect(source.parts.filter { if case .attachment = $0.content { true } else { false } }.count == testCase.filesPerMember)
        }
        for asset in sourceAssets {
            #expect(try await reopened.attachment(id: asset.id, conversationID: f.teamChat) == asset)
        }
        let transcript = try await reopened.page(conversationID: f.teamChat, request: PageRequest(limit: 30)).elements
        #expect(transcript.filter { $0.outputClass == .conversation && $0.author == .teammate(f.mira) }.count == 1)
        #expect(await service.sendHandoffReport(.init(handoffID: current.id)) { _ in }.outcome == .failed(.unavailable))
        #expect(await runner.requests.count == 5)
    }

    @Test("A lead that attempts a fifth member leg is stopped by the durable hop budget")
    func overBudgetContinuationCannotDispatch() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let replies = ["Starting.\n\n" + Self.fence] + (0..<HandoffRecord.maximumChainHops).flatMap { index in
            ["Member report \(index)", "Continuing.\n\n" + Self.fence]
        }
        let runner = HandoffReplyRunner(replies: replies)
        let service = try f.service(store, runner: runner)
        _ = await service.sendText(f.submission(to: f.mira, text: "Ask members")) { _ in }
        for hop in 1...HandoffRecord.maximumChainHops {
            let record = try #require(try await store.records(conversationID: f.teamChat).first { $0.hopCount == hop })
            #expect(await service.sendHandoffLeg(.init(handoffID: record.id)) { _ in }.outcome == .completed)
            let report = await service.sendHandoffReport(.init(handoffID: record.id)) { _ in }
            #expect(report.outcome == (hop == HandoffRecord.maximumChainHops ? .failed(.invalidResponse) : .completed))
            #expect(report.savedReplyMessage?.outputClass == .workAudit)
        }
        let records = try await store.records(conversationID: f.teamChat)
        #expect(records.count == HandoffRecord.maximumChainHops)
        #expect(records.first { $0.hopCount == HandoffRecord.maximumChainHops }?.state == .needsRecovery)
        let lastRequest = try #require(await runner.requests.last)
        #expect(lastRequest.systemPrompt.contains("member-leg budget is exhausted"))
        #expect(!lastRequest.systemPrompt.contains("Delegating:"))
    }

    /// A call made while building hiring: the lead is told
    /// to brief a newcomer only on a turn that can hand off. At the last hop
    /// the budget sentence says it cannot, and a fence there fails the turn.
    @Test("A lead holding the hire switches is told to brief a newcomer by handoff only on turns that can still hand off, never at the last hop")
    func theHireBriefFollowsTheHopBudget() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let hops = HandoffRecord.maximumChainHops
        let replies = ["Starting.\n\n" + Self.fence] + (0..<hops).flatMap { index in
            ["Member report \(index)", index + 1 < hops ? "Continuing.\n\n" + Self.fence : "All done."]
        }
        let runner = HandoffReplyRunner(replies: replies)
        let service = try f.service(store, runner: runner, webAccess: HandoffHireAccess(hirers: [f.mira]),
                                    hiring: HandoffNoHiring())
        #expect(await service.sendText(f.submission(to: f.mira, text: "Ask members")) { _ in }.outcome == .completed)
        for hop in 1...hops {
            let record = try #require(try await store.records(conversationID: f.teamChat).first { $0.hopCount == hop })
            #expect(await service.sendHandoffLeg(.init(handoffID: record.id)) { _ in }.outcome == .completed)
            #expect(await service.sendHandoffReport(.init(handoffID: record.id)) { _ in }.outcome == .completed)
        }
        let requests = await runner.requests
        #expect(requests.count == 1 + 2 * hops)
        let brief = "brief them in this same reply with a normal handoff"
        // The lead's first turn and every report with legs left can hand off.
        for index in [0] + (1..<hops).map({ 2 * $0 }) {
            #expect(requests[index].grantsHiring, "request \(index)")
            #expect(requests[index].systemPrompt.contains(brief), "request \(index)")
        }
        // The last report cannot: a newcomer still joins the team, and nothing says to brief it.
        let last = try #require(requests.last)
        #expect(last.grantsHiring)
        #expect(last.systemPrompt.contains("The member-leg budget is exhausted. You cannot hand off again"))
        #expect(last.systemPrompt.contains("\n- In this team conversation a teammate you hire joins the team.\n"))
        #expect(!last.systemPrompt.contains(brief))
    }

    /// A member's leg answers a brief the lead wrote, which is peer content,
    /// and a hire made there would join the team. So the leg never
    /// carries the hire server; the lead's own report turn, and a message the
    /// person addresses to the member, still do.
    @Test("A member holding the hire switches cannot hire on a leg it answers for the lead; the lead's report and the person's own message to that member can")
    func aMemberLegCannotHire() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = HandoffReplyRunner(replies: ["Asking Ada.\n\n" + Self.fence, "A haiku.", "Here it is.", "Hello."])
        let service = try f.service(store, runner: runner, webAccess: HandoffHireAccess(hirers: [f.mira, f.ada]),
                                    hiring: HandoffNoHiring())
        #expect(await service.sendText(f.submission(to: f.mira, text: "Can someone write a haiku?")) { _ in }.outcome == .completed)
        let record = try #require(try await store.records(conversationID: f.teamChat).first)
        #expect(await service.sendHandoffLeg(.init(handoffID: record.id)) { _ in }.outcome == .completed)
        #expect(await service.sendHandoffReport(.init(handoffID: record.id)) { _ in }.outcome == .completed)
        #expect(await service.sendText(f.submission(to: f.ada, text: "@Ada say hello")) { _ in }.outcome == .completed)
        let requests = await runner.requests
        #expect(requests.count == 4)
        let leg = requests[1]
        #expect(!leg.grantsHiring && !leg.requiresPermissionControl, "Ada's leg: no hire server, no channel")
        #expect(!leg.systemPrompt.contains("hire_teammate"))
        #expect(requests[0].grantsHiring, "the lead answering the person")
        #expect(requests[2].grantsHiring && requests[2].systemPrompt.contains("hire_teammate"), "the lead's own report turn")
        #expect(requests[3].grantsHiring, "the person's own message to the member")
    }

    @Test("Oversized full report context ends in visible recovery without truncation or a provider run")
    func reportContextOverflowNeedsRecovery() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = HandoffReplyRunner(replies: ["Starting.\n\n" + Self.fence,
            String(repeating: "report fact ", count: 5_000)])
        let service = try f.service(store, runner: runner)
        _ = await service.sendText(f.submission(to: f.mira, text: String(repeating: "Request. ", count: 1_600))) { _ in }
        let staged = try #require(try await store.records(conversationID: f.teamChat).first)
        #expect(await service.sendHandoffLeg(.init(handoffID: staged.id)) { _ in }.outcome == .completed)
        #expect(await service.sendHandoffReport(.init(handoffID: staged.id)) { _ in }.outcome == .failed(.invalidInput))
        let record = try #require(try await store.record(id: staged.id))
        #expect(record.state == .needsRecovery && record.handoff.recovery?.code == "report-context-too-large")
        #expect(record.replyMessageID != nil)
        #expect(await runner.requests.count == 2)
    }

    /// The lead's report turn breaks after the member answered: the CLI fails,
    /// the user presses Stop, or the lead returns nothing (persistence refuses
    /// an empty completed reply, so that one settles as a failed save). Each
    /// is a compile that never reached the room, so the record must not read
    /// as done.
    @Test("A report turn that does not compile leaves the record needing attention, never `succeeded` with no answer",
          arguments: [("fails", ClaudeTextTurnOutcome.failed(.runtimeUnavailable), "report-failed",
                       "The lead could not compile the member's answer. The lead can hand this off again."),
                      ("is stopped", .stopped, "report-stopped",
                       "Stopped before the lead compiled the member's answer. The lead can hand this off again."),
                      ("returns nothing", .failed(.invalidResponse), "report-failed",
                       "The lead could not compile the member's answer. The lead can hand this off again.")])
    func reportTurnThatDoesNotCompileNeedsRecovery(
        _ testCase: (how: String, outcome: ClaudeTextTurnOutcome, code: String, message: String)) async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let member = "Silent hands align\none river from many streams\nthe work moves as one"
        let runner = HandoffReplyRunner(replies: ["Ada, over to you.\n\n" + Self.fence, member, ""],
                                        failOnRun: testCase.how == "fails" ? 3 : nil,
                                        stallFromRun: testCase.how == "is stopped" ? 3 : nil)
        let service = try f.service(store, runner: runner)
        _ = await service.sendText(f.submission(to: f.mira, text: "Haiku please")) { _ in }
        let staged = try #require(try await store.records(conversationID: f.teamChat).first)
        let leg = await service.sendHandoffLeg(HandoffLegSubmission(handoffID: staged.id)) { _ in }
        #expect(leg.outcome == .completed)
        let answered = try #require(try await store.record(id: staged.id))
        #expect(answered.state == .succeeded)
        let recorder = ProgressRecorder()
        let report = Task { await service.sendHandoffReport(HandoffReportSubmission(handoffID: staged.id)) { await recorder.append($0) } }
        if testCase.how == "is stopped" {
            // Stop lands once the lead's partial is durable, the way a user's
            // Stop does: the turn is mid-reply, not mid-launch.
            var spins = 0
            while await !recorder.events.contains(where: { if case .assistantMessageSaved = $0 { return true } else { return false } }),
                  spins < 100_000 {
                await Task.yield()
                spins += 1
            }
            #expect(await runner.requests.count == 3)
            report.cancel()
        }
        let result = await report.value
        #expect(result.outcome == testCase.outcome)
        // The lead's turn is on the record as what it was, and the member's
        // report stayed the work-channel message it was sent as.
        let sent = try #require(result.savedUserMessage)
        #expect(sent.author == .teammate(f.ada) && sent.outputClass == .workAudit)
        // The lead's run is closed as what it was, never left running on a lease.
        let run = try #require(try await store.runs(conversationID: f.teamChat, limit: 1).first)
        #expect(run.state == (testCase.outcome == .stopped ? .interrupted : .failed))
        let record = try #require(try await store.record(id: staged.id))
        #expect(record.state == .needsRecovery)
        #expect(record.state != .succeeded && record.state != .returnedToOrigin)
        #expect(record.handoff.recovery?.code == testCase.code)
        #expect(record.handoff.recovery?.userMessage == testCase.message)
        #expect(record.handoff.recovery?.isRecoverable == false)
        // The member's reply stays anchored, so the record still says who answered.
        #expect(record.replyMessageID == answered.replyMessageID)
        // Neither a second compile nor a re-sent leg is admitted for a record in recovery.
        #expect(await service.sendHandoffReport(HandoffReportSubmission(handoffID: staged.id)) { _ in }.outcome == .failed(.unavailable))
        #expect(await service.sendHandoffLeg(HandoffLegSubmission(handoffID: staged.id)) { _ in }.outcome == .failed(.unavailable))
        // A result that never reached the room is not quoted back as if it had.
        _ = await service.sendText(f.submission(to: f.mira, text: "So what did Ada say?")) { _ in }
        let leadRequest = try #require(await runner.requests.last)
        #expect(!leadRequest.systemPrompt.contains("Results returned from members"))
        #expect(try await store.record(id: staged.id)?.state == .needsRecovery)
    }

    @Test("A file the member leaves in its Outbox reaches the user as a chip on the lead's compiled answer")
    func memberOutboxFileBecomesAChipOnTheLeadsAnswer() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let home = f.directory.appending(path: "Ada", directoryHint: .isDirectory)
        let outbox = home.appending(path: BotWorkspaceService.outboxName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        let access = try ClaudeTextWorkAccess(workingDirectoryURL: home, protectedPaths: [])
        // The member writes the haiku to its Outbox during its leg (run 2).
        let runner = HandoffReplyRunner(replies: ["Ada, over to you.\n\n" + Self.fence,
                                                 "The haiku is in my Outbox as haiku.md.",
                                                 "Here it is: Ada's haiku, attached."],
                                        onRun: { run in
            if run == 2 { try Data("Silent hands align\n".utf8).write(to: outbox.appending(path: "haiku.md")) }
        })
        let attachments = f.attachments(store)
        let service = try f.service(store, runner: runner,
            webAccess: HandoffWorkAccess(teammateID: f.ada, access: access), deliverables: attachments)
        _ = await service.sendText(f.submission(to: f.mira, text: "Haiku please")) { _ in }
        let staged = try #require(try await store.records(conversationID: f.teamChat).first)
        let leg = await service.sendHandoffLeg(HandoffLegSubmission(handoffID: staged.id)) { _ in }
        #expect(leg.outcome == .completed)
        let report = await service.sendHandoffReport(HandoffReportSubmission(handoffID: staged.id)) { _ in }
        #expect(report.outcome == .completed)
        let answer = try #require(report.savedReplyMessage)
        #expect(answer.author == .teammate(f.mira) && answer.outputClass == .conversation)
        // The user sees the lead's bubble only, so that is where the chip must be.
        let chips = answer.parts.compactMap { part -> (MessagePartID, AttachmentID)? in
            if case .attachment(let id) = part.content { (part.id, id) } else { nil }
        }
        #expect(chips.count == 1)
        guard let chip = chips.first else { return }
        #expect(answer.parts.first?.content == .text("Here it is: Ada's haiku, attached."))
        // And the chip resolves the way the bubble resolves it, for Open and Reveal.
        let asset = try await attachments.attachment(messageID: answer.id, partID: chip.0, attachmentID: chip.1)
        #expect(asset.displayName == "haiku.md" && asset.byteCount == 19)
        // The member's own reply keeps the file on the record.
        let memberReplyID = try #require(leg.savedReplyMessage?.id)
        let memberReply = try #require(try await store.message(id: memberReplyID))
        #expect(memberReply.parts.contains { if case .attachment(chip.1) = $0.content { true } else { false } })
    }

    @Test("A failed leg needs recovery and keeps its partial reply; a leg cannot be sent twice or without the repository")
    func legFailureAndRefusals() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = HandoffReplyRunner(replies: ["Go.\n\n" + Self.fence], failAfterFirst: true)
        let service = try f.service(store, runner: runner)
        _ = await service.sendText(f.submission(to: f.mira, text: "Delegate")) { _ in }
        let staged = try #require(try await store.records(conversationID: f.teamChat).first)
        let failed = await service.sendHandoffLeg(HandoffLegSubmission(handoffID: staged.id)) { _ in }
        #expect(failed.outcome == .failed(.runtimeUnavailable))
        #expect(try #require(failed.savedReplyMessage).parts.first?.content == .text("partial"))
        let record = try #require(try await store.record(id: staged.id))
        #expect(record.state == .needsRecovery)
        // A leg in recovery cannot be re-sent, so the copy does not offer it.
        #expect(record.handoff.recovery?.code == "leg-failed" && record.handoff.recovery?.isRecoverable == false)
        #expect(record.handoff.recovery?.userMessage
            == "The member's reply did not complete. The lead can hand this off again.")
        let again = await service.sendHandoffLeg(HandoffLegSubmission(handoffID: staged.id)) { _ in }
        #expect(again.outcome == .failed(.unavailable))
        let unknown = await service.sendHandoffLeg(HandoffLegSubmission(handoffID: HandoffID(UUID()))) { _ in }
        #expect(unknown.outcome == .failed(.unavailable))
        let without = try f.service(store, runner: runner, handoffs: false)
        let refused = await without.sendHandoffLeg(HandoffLegSubmission(handoffID: staged.id)) { _ in }
        #expect(refused.outcome == .failed(.unavailable))
    }

    @Test("A stopped leg claims its receiver while it runs and ends in recovery, not stuck working")
    func legStoppedByCancellation() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        // Two staged cards for the same member: one runs, the other proves the
        // receiver is claimed. Re-sending the running card is refused earlier,
        // by its state, so it cannot exercise the busy guard.
        let runner = HandoffReplyRunner(replies: ["Go.\n\n" + Self.fence, "Again.\n\n" + Self.fence],
                                        stallFromRun: 3)
        let service = try f.service(store, runner: runner)
        _ = await service.sendText(f.submission(to: f.mira, text: "Delegate")) { _ in }
        _ = await service.sendText(f.submission(to: f.mira, text: "Delegate again")) { _ in }
        let cards = try await store.records(conversationID: f.teamChat)
        #expect(cards.count == 2)
        let staged = try #require(cards.first), other = try #require(cards.last)
        let leg = Task { await service.sendHandoffLeg(HandoffLegSubmission(handoffID: staged.id)) { _ in } }
        // The member is mid-reply once its run has started, which is also proof
        // that the record already moved to working.
        var spins = 0
        while await runner.requests.count < 3, spins < 100_000 {
            await Task.yield()
            spins += 1
        }
        #expect(await runner.requests.count == 3)
        let busy = await service.sendHandoffLeg(HandoffLegSubmission(handoffID: other.id)) { _ in }
        #expect(busy.outcome == .failed(.busy))
        #expect(try await store.record(id: other.id)?.state == .staged)
        // Re-sending the card that is already running is refused by its state.
        let running = await service.sendHandoffLeg(HandoffLegSubmission(handoffID: staged.id)) { _ in }
        #expect(running.outcome == .failed(.unavailable))
        leg.cancel()
        #expect(await leg.value.outcome == .stopped)
        // Stop cancels the caller's task; the ledger write has to outlive it.
        let record = try #require(try await store.record(id: staged.id))
        #expect(record.state == .needsRecovery)
        #expect(record.handoff.recovery?.code == "leg-stopped" && record.handoff.recovery?.isRecoverable == false)
        #expect(record.handoff.recovery?.userMessage
            == "Stopped before the member answered. The lead can hand this off again.")
    }

    @Test("A fence arriving across snapshots is withheld from every checkpoint, even when an earlier opener dissolves")
    func fenceIsWithheldAcrossSnapshots() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        // Snapshot 3 ends on a second opener line that snapshot 4 dissolves. A
        // cut at the last opener would jump backwards there, the checkpoint
        // would shrink, and persistence would kill the run.
        let closing = "\n\n" + Self.fence
        let snapshots = ["A",
                         "A\n```handoff",
                         "A\n```handoff\nB\n```handoff",
                         "A\n```handoff\nB\n```handoff2",
                         "A\n```handoff\nB\n```handoff2" + closing]
        let runner = HandoffReplyRunner(replies: [snapshots])
        let service = try f.service(store, runner: runner)
        let result = await service.sendText(f.submission(to: f.mira, text: "Delegate")) { _ in }
        #expect(result.outcome == .completed)
        // Only the closed fence region is deleted; the stray lines are text.
        #expect(try #require(result.savedReplyMessage).parts.first?.content
            == .text("A\n```handoff\nB\n```handoff2\n\n"))
        let records = try await store.records(conversationID: f.teamChat)
        #expect(records.count == 1 && records.first?.state == .staged)
    }

    static let savedReplyCases: [(name: String, reply: String, saved: String)] = [
        ("leading whitespace", "  I'll ask Ada.\n\n" + fence, "  I'll ask Ada.\n\n"),
        ("text after the fence", "Before.\n" + fence + "\nAfter.", "Before.\n\nAfter."),
        ("a dangling second opener", "A\n" + fence + "\n```handoff", "A\n\n```handoff"),
        ("nothing but the fence", fence, "Handing this off."),
    ]

    @Test("The saved reply is the lead's text with only the fence region deleted",
          arguments: savedReplyCases)
    func savedReplyDeletesOnlyTheFence(_ testCase: (name: String, reply: String, saved: String)) async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = HandoffReplyRunner(replies: [testCase.reply])
        let service = try f.service(store, runner: runner)
        let result = await service.sendText(f.submission(to: f.mira, text: "Delegate")) { _ in }
        #expect(result.outcome == .completed, "\(testCase.name) did not complete")
        #expect(try #require(result.savedReplyMessage).parts.first?.content == .text(testCase.saved),
                "\(testCase.name) saved the wrong text")
        let records = try await store.records(conversationID: f.teamChat)
        #expect(records.count == 1 && records.first?.state == .staged, "\(testCase.name) did not stage")
    }

    @Test("A refusal the record itself causes happens before the accept, so the card stays staged")
    func deterministicRefusalsLeaveTheCardStaged() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = HandoffReplyRunner(replies: ["Go.\n\n" + Self.fence])
        let service = try f.service(store, runner: runner)
        _ = await service.sendText(f.submission(to: f.mira, text: "Delegate")) { _ in }
        let staged = try #require(try await store.records(conversationID: f.teamChat).first)
        // A brief the domain accepts can still render past the run input limit.
        let huge = try Handoff(provenance: HandoffProvenance(handoffID: HandoffID(UUID()), legID: HandoffLegID(UUID()),
            originConversationID: f.teamChat, senderID: f.mira, receiverID: f.ada, createdAt: f.date),
            brief: HandoffBrief(goal: "Big", constraints: Array(repeating: String(repeating: "c", count: 1_000), count: 32),
                inputReferences: Array(repeating: String(repeating: "i", count: 1_000), count: 64),
                requestedOutput: "Out", exclusions: [], stopOrApprovalBoundary: "Stop"))
        try await store.insert(HandoffRecord(handoff: huge, sourceMessageID: nil))
        let oversize = await service.sendHandoffLeg(HandoffLegSubmission(handoffID: huge.provenance.handoffID)) { _ in }
        #expect(oversize.outcome == .failed(.invalidInput))
        #expect(try await store.record(id: huge.provenance.handoffID)?.state == .staged)
        // The receiver's saved model is refused the same way sendText refuses it.
        var ada = try #require(try await store.teammate(id: f.ada))
        let revision = ada.profile.revision
        ada.claudeModel = "retired-model"
        ada.profile = try ada.profile.revised()
        try await store.update(ada, expectedProfileRevision: revision)
        let unsupported = await service.sendHandoffLeg(HandoffLegSubmission(handoffID: staged.id)) { _ in }
        #expect(unsupported.outcome == .failed(.modelUnavailable))
        #expect(try await store.record(id: staged.id)?.state == .staged)
        #expect(await runner.requests.count == 1)
    }

    @Test("An archived receiver and one no longer in the team are both refused",
          arguments: ["archived", "notAMember"])
    func refusalsForAnAbsentReceiver(_ mode: String) async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = HandoffReplyRunner(replies: ["Go.\n\n" + Self.fence])
        let service = try f.service(store, runner: runner)
        _ = await service.sendText(f.submission(to: f.mira, text: "Delegate")) { _ in }
        let staged = try #require(try await store.records(conversationID: f.teamChat).first)
        if mode == "archived" {
            var ada = try #require(try await store.teammate(id: f.ada))
            let revision = ada.profile.revision
            ada.lifecycle = .archived
            ada.profile = try ada.profile.revised()
            try await store.update(ada, expectedProfileRevision: revision)
        } else {
            // A record naming a non-member cannot be inserted (the schema's
            // origin trigger refuses it), so the membership is revoked instead.
            var team = try #require(try await store.team(id: f.teamID))
            try team.removeMember(f.ada)
            team.updatedAt = Date()
            try await store.update(team)
        }
        let result = await service.sendHandoffLeg(HandoffLegSubmission(handoffID: staged.id)) { _ in }
        #expect(result.outcome == .failed(.unavailable))
        #expect(try await store.record(id: staged.id)?.state == .staged)
        #expect(await runner.requests.count == 1)
    }

    @Test("A refusal after the accept leaves the record accepted, and a later send still runs the member")
    func refusalAfterTheAcceptCanBeSentAgain() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = HandoffReplyRunner(replies: ["Ada, over to you.\n\n" + Self.fence,
                                                 "Silent hands align\none river from many streams\nthe work moves as one"])
        let preparer = HandoffReplyPreparer(target: try f.target())
        let service = try f.service(store, runner: runner, preparer: preparer)
        _ = await service.sendText(f.submission(to: f.mira, text: "Haiku please")) { _ in }
        let staged = try #require(try await store.records(conversationID: f.teamChat).first)
        // Readiness is withdrawn after the lead's turn, so the refusal lands
        // between the accept and the durable turn: exactly the window a Stop or
        // an uninstalled CLI opens. Nothing ran, so nothing was saved.
        await preparer.refuse(.setupRequired)
        let refused = await service.sendHandoffLeg(HandoffLegSubmission(handoffID: staged.id)) { _ in }
        #expect(refused.outcome == .failed(.setupRequired))
        #expect(refused.savedReplyMessage == nil)
        #expect(await runner.requests.count == 1)
        let accepted = try #require(try await store.record(id: staged.id))
        #expect(accepted.state == .accepted && accepted.briefMessageID == nil && accepted.runID == nil)
        // The card is not a dead end: the same record runs on the next click.
        await preparer.refuse(nil)
        let sent = await service.sendHandoffLeg(HandoffLegSubmission(handoffID: staged.id)) { _ in }
        #expect(sent.outcome == .completed)
        #expect(try #require(sent.savedReplyMessage).author == .teammate(f.ada))
        let done = try #require(try await store.record(id: staged.id))
        #expect(done.state == .succeeded)
        #expect(done.handoff.resultSummary?.hasPrefix("Silent hands align") == true)
    }

    @Test("A delegation that cannot be staged keeps its fence in the saved reply and stages nothing")
    func unstageableDelegationKeepsTheFence() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let text = "I'll ask Ada.\n\n" + Self.fence
        let runner = HandoffReplyRunner(replies: [text])
        let handoffs = HandoffInsertFailingRepository(store, failures: 1)
        let service = try f.service(store, runner: runner, handoffRepository: handoffs)
        let result = await service.sendText(f.submission(to: f.mira, text: "Haiku please")) { _ in }
        // The turn still completes; the user sees the whole reply the lead
        // wrote rather than a stripped one with no card to show for it.
        #expect(result.outcome == .completed)
        #expect(try #require(result.savedReplyMessage).parts.first?.content == .text(text))
        #expect(await handoffs.inserts == 1)
        #expect(try await store.records(conversationID: f.teamChat).isEmpty)
    }

    @Test("Without the handoff repository the lead is not offered delegation and a fence stays text")
    func noRepositoryNoDelegation() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = HandoffReplyRunner(replies: ["Plain.\n\n" + Self.fence])
        let service = try f.service(store, runner: runner, handoffs: false)
        let result = await service.sendText(f.submission(to: f.mira, text: "Hi")) { _ in }
        let request = try #require(await runner.requests.first)
        #expect(!request.systemPrompt.contains("Delegating:"))
        let reply = try #require(result.savedReplyMessage)
        #expect(reply.parts.first?.content == .text("Plain.\n\n" + Self.fence))
    }
}

private actor ProgressRecorder {
    private(set) var events: [ClaudeTextTurnProgress] = []
    func append(_ event: ClaudeTextTurnProgress) { events.append(event) }
}

// MARK: A member's file that is gone

/// Every card and line a turn shows, so a test can answer a card while the
/// turn waits on it.
private actor CardLog {
    private(set) var approvals: [ClaudeTextApproval] = []
    private(set) var activities: [String] = []
    func append(_ event: ClaudeTextTurnProgress) {
        switch event {
        case .approvalRequired(let approval): approvals.append(approval)
        case .activity(let line): activities.append(line)
        default: break
        }
    }
    func waitForApproval(count: Int = 1) async throws -> ClaudeTextApproval {
        for _ in 0..<800 {
            if approvals.count >= count { return approvals[count - 1] }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CardLogError.timedOut
    }
}

private enum CardLogError: Error { case timedOut }

extension HandoffTextReplyTests.Fixture {
    /// Owned copies kept on disk the way the app keeps them, one file per
    /// chip, and checked against the record before use: the contract of the
    /// app's content store, whose verifier throws when the copy is gone.
    var blobs: URL { directory.appending(path: "Attachments", directoryHint: .isDirectory) }
    func blob(_ id: AttachmentID) -> URL { blobs.appending(path: id.persistedValue + ".blob") }
    func diskAttachments(_ store: SQLiteStore) -> ConversationAttachmentService {
        let blobs = blobs
        try? FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        return ConversationAttachmentService(repository: store, messages: store,
            importer: { url, id in
                let data = try Data(contentsOf: url)
                try data.write(to: blobs.appending(path: id.persistedValue + ".blob"))
                return try StoredAttachmentContent(id: id, byteCount: Int64(data.count),
                    sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                    typeIdentifier: "net.daringfireball.markdown", displayName: url.lastPathComponent)
            },
            verifier: { asset in
                let path = blobs.appending(path: asset.id.persistedValue + ".blob").path
                let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber
                guard size?.int64Value == asset.byteCount else { throw ConversationAttachmentError.attachmentUnavailable }
            },
            location: { _ in throw ConversationAttachmentError.unavailable })
    }
    func file(_ name: String, _ text: String) throws -> URL {
        let url = directory.appending(path: name)
        try Data(text.utf8).write(to: url)
        return url
    }
}

extension HandoffTextReplyTests {
    /// A chain that ended with two of Ada's files on her reply: the lead
    /// asked Ada, Ada answered with the files, the report handed on to Zed,
    /// and Zed's leg was declined. The next lead turn returns Ada's results.
    fileprivate func endedChainWithTwoFiles(_ f: Fixture, then replies: [String],
                                            clock: any OpenBotsClock = SystemClock()) async throws
        -> (store: SQLiteStore, runner: HandoffReplyRunner, service: OfficialClaudeTextReplyService,
            files: [AttachmentAsset], first: HandoffRecord) {
        let store = try f.open()
        try await f.seed(store, includeZed: true)
        let nextFence = Self.fence.replacingOccurrences(of: "\"Ada\"", with: "\"Zed\"")
        let runner = HandoffReplyRunner(replies: ["I'll ask Ada.\n\n" + Self.fence, "ADA_FINDING",
            "Now Zed.\n\n" + nextFence] + replies)
        let attachments = f.diskAttachments(store)
        let service = try f.service(store, runner: runner, deliverables: attachments, clock: clock,
                                    heartbeat: .milliseconds(20))
        #expect(await service.sendText(f.submission(to: f.mira, text: "Ask Ada, then Zed.")) { _ in }.outcome == .completed)
        let first = try #require(try await store.records(conversationID: f.teamChat).first)
        let leg = await service.sendHandoffLeg(.init(handoffID: first.id)) { _ in }
        #expect(leg.outcome == .completed)
        let files = await attachments.attachProducedFiles([try f.file("a.md", "alpha"), try f.file("b.md", "beta")],
            toReply: try #require(leg.savedReplyMessage).id, conversationID: f.teamChat)
        #expect(files.count == 2)
        #expect(await service.sendHandoffReport(.init(handoffID: first.id)) { _ in }.outcome == .completed)
        for record in try await store.records(conversationID: f.teamChat) where record.state == .staged {
            _ = try await HandoffService(repository: store).decline(id: record.id)
        }
        return (store, runner, service, files, first)
    }

    private static func chips(_ message: Message?) -> [AttachmentID] {
        (message?.parts ?? []).compactMap { if case .attachment(let id) = $0.content { id } else { nil } }
    }

    @Test("A member's file gone from disk puts a card up before the lead runs; Continue without it returns the rest, and the next turn is free")
    func missingFileCardContinueWithout() async throws {
        let f = try Fixture(); defer { f.remove() }
        let (store, runner, service, files, first) = try await endedChainWithTwoFiles(f,
            then: ["Here is what Ada found.", "Nothing new."])
        try FileManager.default.removeItem(at: f.blob(files[0].id))
        let before = await runner.requests.count
        let log = CardLog()
        let lead = Task { await service.sendText(f.submission(to: f.mira, text: "What did Ada find?")) { await log.append($0) } }
        let card = try await log.waitForApproval()
        #expect(card.asksForMissingFile)
        #expect(card.title == "Ada's file can't be found")
        #expect(card.detail.contains("Ada's file “a.md”") && card.detail.contains("Mira's reply waits"), "\(card.detail)")
        #expect(card.target == "a.md")
        #expect(card.turnScopeFolder == nil)
        #expect(await runner.requests.count == before, "nothing runs while the card waits")
        #expect(!(await service.allowApprovalForTurn(id: card.id)))
        #expect(!(await service.decideApproval(id: card.id, allow: true)), "Approve alone chooses no file")
        #expect(await service.decideApproval(id: card.id, allow: false))
        let result = await lead.value
        #expect(result.outcome == .completed)
        #expect(Self.chips(result.savedReplyMessage) == [files[1].id])
        let lines = await log.activities
        #expect(lines.contains("Continued without Ada's file “a.md”: the results came back without it."), "\(lines)")
        #expect(try await store.record(id: first.id)?.state == .returnedToOrigin)
        let next = CardLog()
        #expect(await service.sendText(f.submission(to: f.mira, text: "Thanks.")) { await next.append($0) }.outcome == .completed)
        #expect(await next.approvals.isEmpty)
        #expect(!(try #require(await runner.requests.last).systemPrompt.contains("ADA_FINDING")))
    }

    @Test("Choose the file puts the chosen file in the missing one's place on the lead's reply only")
    func missingFileCardChooseTheFile() async throws {
        let f = try Fixture(); defer { f.remove() }
        let (store, _, service, files, first) = try await endedChainWithTwoFiles(f, then: ["Here is what Ada found."])
        try FileManager.default.removeItem(at: f.blob(files[0].id))
        let log = CardLog()
        let lead = Task { await service.sendText(f.submission(to: f.mira, text: "What did Ada find?")) { await log.append($0) } }
        let card = try await log.waitForApproval()
        let chosen = try f.file("a-again.md", "alpha, found again")
        #expect(await service.replaceMissingFile(id: card.id, with: chosen))
        #expect(!(await service.decideApproval(id: card.id, allow: false)), "a card is answered once")
        let result = await lead.value
        #expect(result.outcome == .completed)
        let carried = Self.chips(result.savedReplyMessage)
        #expect(carried.count == 2 && carried.last == files[1].id && !carried.contains(files[0].id), "\(carried)")
        let replacement = try #require(try await store.attachment(id: carried[0], conversationID: f.teamChat))
        #expect(replacement.displayName == "a-again.md")
        // Ada's own reply is left as it was.
        let legReply = try #require(try await store.record(id: first.id)?.replyMessageID)
        #expect(Self.chips(try await store.message(id: legReply)) == files.map(\.id))
        let lines = await log.activities
        #expect(lines.contains("Put “a-again.md” in place of Ada's missing file “a.md”."), "\(lines)")
    }

    @Test("A file whose record is gone is still asked about, without a name")
    func missingRecordStillAsks() async throws {
        let f = try Fixture(); defer { f.remove() }
        let (store, _, service, files, _) = try await endedChainWithTwoFiles(f, then: ["Here is what Ada found."])
        // Not reachable in the app today (nothing deletes a chip's record in a
        // live team chat); the check covers it all the same.
        _ = try await store.execute(sql: "DELETE FROM attachment_assets WHERE id=?;", bindings: [.text(files[0].id.persistedValue)])
        let log = CardLog()
        let lead = Task { await service.sendText(f.submission(to: f.mira, text: "What did Ada find?")) { await log.append($0) } }
        let card = try await log.waitForApproval()
        #expect(card.detail.contains("One of Ada's files"), "\(card.detail)")
        #expect(await service.decideApproval(id: card.id, allow: false))
        let result = await lead.value
        #expect(result.outcome == .completed)
        #expect(Self.chips(result.savedReplyMessage) == [files[1].id])
    }

    @Test("A card nobody answers, or a Stop while it waits, leaves the results for the next lead turn, which asks again")
    func unansweredCardKeepsTheResults() async throws {
        let f = try Fixture(); defer { f.remove() }
        let (store, runner, service, files, first) = try await endedChainWithTwoFiles(f, then: ["Here is what Ada found."])
        try FileManager.default.removeItem(at: f.blob(files[0].id))
        let before = await runner.requests.count
        // Expired.
        let log = CardLog()
        let expired = Task { await service.sendText(f.submission(to: f.mira, text: "What did Ada find?")) { await log.append($0) } }
        await service.expireApproval(id: try await log.waitForApproval().id)
        #expect(await expired.value.outcome == .stopped)
        #expect(try await store.record(id: first.id)?.state == .succeeded)
        #expect(await runner.requests.count == before)
        // Stopped.
        let stopLog = CardLog()
        let stopped = Task { await service.sendText(f.submission(to: f.mira, text: "And now?")) { await stopLog.append($0) } }
        let stopCard = try await stopLog.waitForApproval()
        stopped.cancel()
        #expect(await stopped.value.outcome == .stopped)
        #expect(!(await service.decideApproval(id: stopCard.id, allow: false)), "the card went with the turn")
        #expect(try await store.record(id: first.id)?.state == .succeeded)
        #expect(await runner.requests.count == before)
        // The next turn asks again, and this time goes on.
        let again = CardLog()
        let third = Task { await service.sendText(f.submission(to: f.mira, text: "Once more.")) { await again.append($0) } }
        #expect(await service.decideApproval(id: try await again.waitForApproval().id, allow: false))
        #expect(await third.value.outcome == .completed)
        #expect(try await store.record(id: first.id)?.state == .returnedToOrigin)
    }
}

/// A clock the test moves forward, so a card can be answered after minutes.
private final class JumpClock: OpenBotsClock, @unchecked Sendable {
    private let lock = NSLock()
    private var offset: TimeInterval = 0
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return Date().addingTimeInterval(offset) }
    func jump(_ seconds: TimeInterval) { lock.lock(); offset += seconds; lock.unlock() }
    /// A minute at a time, with a pause for the card's renewal after each.
    func advance(_ seconds: TimeInterval) async throws {
        var left = seconds
        while left > 0 {
            jump(min(50, left)); left -= 50
            try await Task.sleep(for: .milliseconds(200))
        }
    }
}

extension HandoffTextReplyTests {
    @Test("A card answered minutes later still lets the lead run, and one that expires leaves the bot free")
    func slowAnswersKeepTheTurnAlive() async throws {
        let f = try Fixture(); defer { f.remove() }
        let clock = JumpClock()
        let (store, _, service, files, first) = try await endedChainWithTwoFiles(f,
            then: ["Here is what Ada found."], clock: clock)
        try FileManager.default.removeItem(at: f.blob(files[0].id))
        // Nobody answers for the card's whole life.
        let log = CardLog()
        let expired = Task { await service.sendText(f.submission(to: f.mira, text: "What did Ada find?")) { await log.append($0) } }
        let card = try await log.waitForApproval()
        try await clock.advance(OfficialClaudeTextReplyService.approvalLifetime + 5)
        await service.expireApproval(id: card.id)
        #expect(await expired.value.outcome == .stopped)
        // The user answers four minutes in: the bot was not left busy, and the reply runs.
        let later = CardLog()
        let answered = Task { await service.sendText(f.submission(to: f.mira, text: "And now?")) { await later.append($0) } }
        let second = try await later.waitForApproval()
        try await clock.advance(240)
        #expect(await service.decideApproval(id: second.id, allow: false))
        #expect(await answered.value.outcome == .completed)
        #expect(try await store.record(id: first.id)?.state == .returnedToOrigin)
    }

    @Test("Five missing files, each answered quicker than the renewal comes, keep the lease alive across the cards")
    func severalSlowCardsKeepTheLease() async throws {
        let f = try Fixture(); defer { f.remove() }
        let clock = JumpClock()
        let store = try f.open()
        try await f.seed(store, includeZed: true)
        let nextFence = Self.fence.replacingOccurrences(of: "\"Ada\"", with: "\"Zed\"")
        let runner = HandoffReplyRunner(replies: ["I'll ask Ada.\n\n" + Self.fence, "ADA_FINDING",
            "Now Zed.\n\n" + nextFence, "Here is what Ada found."])
        let attachments = f.diskAttachments(store)
        // Each card is answered before a renewal is due, so only one renewal
        // running across the cards keeps the lease: 5 × 45 s is past its 180 s.
        let service = try f.service(store, runner: runner, deliverables: attachments, clock: clock,
                                    heartbeat: .milliseconds(100))
        #expect(await service.sendText(f.submission(to: f.mira, text: "Ask Ada, then Zed.")) { _ in }.outcome == .completed)
        let first = try #require(try await store.records(conversationID: f.teamChat).first)
        let leg = await service.sendHandoffLeg(.init(handoffID: first.id)) { _ in }
        let files = await attachments.attachProducedFiles(try ["a", "b", "c", "d", "e"].map { try f.file("\($0).md", $0) },
            toReply: try #require(leg.savedReplyMessage).id, conversationID: f.teamChat)
        #expect(await service.sendHandoffReport(.init(handoffID: first.id)) { _ in }.outcome == .completed)
        for record in try await store.records(conversationID: f.teamChat) where record.state == .staged {
            _ = try await HandoffService(repository: store).decline(id: record.id)
        }
        for file in files { try FileManager.default.removeItem(at: f.blob(file.id)) }
        let log = CardLog()
        let lead = Task { await service.sendText(f.submission(to: f.mira, text: "What did Ada find?")) { await log.append($0) } }
        for index in 1...5 {
            let card = try await log.waitForApproval(count: index)
            clock.jump(45)
            try await Task.sleep(for: .milliseconds(60))
            #expect(await service.decideApproval(id: card.id, allow: false))
        }
        #expect(await lead.value.outcome == .completed)
        #expect(try await store.record(id: first.id)?.state == .returnedToOrigin)
    }

    @Test("A file that cannot be taken leaves the card up, to choose again or continue without it")
    func refusedReplacementKeepsTheCard() async throws {
        let f = try Fixture(); defer { f.remove() }
        let (_, _, service, files, _) = try await endedChainWithTwoFiles(f, then: ["Here is what Ada found."])
        try FileManager.default.removeItem(at: f.blob(files[0].id))
        let log = CardLog()
        let lead = Task { await service.sendText(f.submission(to: f.mira, text: "What did Ada find?")) { await log.append($0) } }
        let card = try await log.waitForApproval()
        #expect(!(await service.replaceMissingFile(id: card.id, with: f.directory.appending(path: "no-such-file.md"))))
        #expect(await log.activities.contains(OfficialClaudeTextReplyService.replacementRefusedLine))
        #expect(await service.decideApproval(id: card.id, allow: false), "the card is still up")
        #expect(await lead.value.outcome == .completed)
    }
}
