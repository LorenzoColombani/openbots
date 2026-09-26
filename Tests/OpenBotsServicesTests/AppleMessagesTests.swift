import Darwin
import Foundation
import OpenBotsDomain
import OpenBotsRuntime
import Testing
@testable import OpenBotsServices

private let messagesServerKey = "openbots_" + String(repeating: "e", count: 64)

private func messagesLaunch(command: String = AppleMessagesConnectorPreparation.command,
                            transport: ConnectorTransport = .stdio) -> ConnectorLaunchConfiguration {
    ConnectorLaunchConfiguration(serverKey: messagesServerKey, transport: transport, command: command,
                                 arguments: [])
}

private func messagesQuestion(_ tool: String, _ input: [String: Any]) throws -> ClaudeTextPermissionRequest {
    ClaudeTextPermissionRequest(requestID: "req-7", toolUseID: "toolu_07",
        toolName: "mcp__\(messagesServerKey)__\(tool)",
        inputJSON: try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]))
}

private func sendCard(_ input: [String: Any]) throws -> ClaudeTextWorkCard {
    let decision = ClaudeTextConnectorApprovalPolicy.decide(try messagesQuestion("send_message", input),
                                                           botName: "Kite", role: .appleMessages)
    guard case .ask(let card) = decision else {
        Issue.record("expected a card, got \(decision)")
        throw CancellationError()
    }
    return card
}

/// Scalar for scalar. Swift's `==` treats canonically equivalent strings as
/// equal, which is exactly the leniency a card that must show the sent bytes
/// cannot have.
private func sameScalars(_ a: String, _ b: String) -> Bool {
    a.unicodeScalars.elementsEqual(b.unicodeScalars)
}

/// A fake Messages.app and a history file, so every badge is decided by the
/// fixture — never by this Mac's own Messages, and never by whether the process
/// running the suite happens to hold Full Disk Access (a developer's shell
/// can often read the real chat.db, and a test leaning on that would pass
/// here and fail everywhere else).
private struct MessagesFixture {
    enum History { case readable, unreadable, missing }

    let root: URL
    let application: URL
    let database: URL

    init(installApplication: Bool = true, history: History = .readable) throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("openbots-messages-prep-\(UUID().uuidString)", isDirectory: true)
        application = root.appendingPathComponent("Applications/Messages.app", isDirectory: true)
        database = root.appendingPathComponent("Library/Messages/chat.db")
        let manager = FileManager()
        try manager.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        if installApplication { try manager.createDirectory(at: application, withIntermediateDirectories: true) }
        switch history {
        case .missing:
            break
        case .readable, .unreadable:
            try Data("SQLite format 3\u{0}".utf8).write(to: database)
            if history == .unreadable {
                // What privacy protection does to a process without Full Disk
                // Access is refuse the open; a mode of 000 is the nearest
                // refusal a test can make without it, and it goes through the
                // same `open(2)` path.
                try manager.setAttributes([.posixPermissions: NSNumber(value: Int16(0o000))],
                                          ofItemAtPath: database.path)
            }
        }
    }

    func preparation(scriptURL: URL? = AppOwnedConnectorCatalog.appleMessagesScriptURL,
                     interpreters: [URL] = [URL(fileURLWithPath: "/bin/sh")],
                     fence: FenceProxyResource = FenceProxyResource(
                        interpreterCandidateURLs: [URL(fileURLWithPath: "/bin/sh")])) -> AppleMessagesConnectorPreparation {
        AppleMessagesConnectorPreparation(scriptURL: scriptURL, applicationCandidateURLs: [application],
                                          databaseURL: database, interpreterCandidateURLs: interpreters,
                                          fence: fence)
    }

    func remove() {
        try? FileManager().setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))],
                                         ofItemAtPath: database.path)
        try? FileManager().removeItem(at: root)
    }
}

private actor MessagesMemoryRepository: ConnectorAccessRepository {
    private var state = ConnectorAccessState()
    func loadConnectorAccess() async throws -> ConnectorAccessState { state }
    func saveConnectorAccess(_ next: ConnectorAccessState, expectedRevision: Int64) async throws {
        guard state.revision == expectedRevision else { throw ConnectorAccessError.staleRevision }
        state = next
    }
}

private struct MessagesOnlyCatalog: ConnectorCatalogReading {
    let connector: ConfiguredConnector
    func loadConnectorCatalog() async throws -> ConnectorCatalogSnapshot { .init(connectors: [connector]) }
}

@Suite("Texting from the user's own number: the launch")
struct AppleMessagesPreparationTests {
    @Test("The server ships in the bundle and launches fenced, with the history and the Messages this side resolved")
    func theServerShipsFenced() throws {
        let fixture = try MessagesFixture(); defer { fixture.remove() }
        let script = try #require(AppOwnedConnectorCatalog.appleMessagesScriptURL)
        #expect(script.lastPathComponent == "apple-messages.js")
        let preparation = fixture.preparation()
        // Building the server at all proves the environment allow-list: a key
        // it does not name throws `invalidServer` here, and only here.
        let server = try preparation.server(for: messagesLaunch(), profileURL: nil,
            temporaryDirectoryURL: FileManager().temporaryDirectory,
            fence: FenceProxyResource(interpreterCandidateURLs: [URL(fileURLWithPath: "/bin/sh")]))
        #expect(server.role == .appleMessages)
        // Somebody else wrote what read_messages hands back, so the shim runs
        // first and the server is its argument.
        #expect(server.program.isFenced)
        #expect(ClaudeTextConnectorRole.appleMessages.handsBackUntrustedMaterial)
        #expect(server.arguments.contains("apple-messages"))
        #expect(server.arguments.last == script.standardizedFileURL.path)
        // A launch that names no chats still says so, as an empty list: the
        // server reads nothing either way, and never everything.
        #expect(server.environment == [
            "OPENBOTS_APP_NAME": "OpenBots Next",
            "OPENBOTS_MESSAGES_APP": fixture.application.standardizedFileURL.path,
            "OPENBOTS_MESSAGES_DB": fixture.database.standardizedFileURL.path,
            AppleMessagesChatScope.environmentKey: AppleMessagesChatScope(guids: []).environmentValue,
        ])
        #expect(server.chatScope == AppleMessagesChatScope(guids: []))
        #expect(server.options.isEmpty)
        #expect(!preparation.needsOwnedProfile)
    }

    @Test("The chats a bot may read reach the server whole, and the launch remembers them for the rest of the turn")
    func theChatsReachTheServer() throws {
        let fixture = try MessagesFixture(); defer { fixture.remove() }
        // The widest list that fits, each guid the longest that can be chosen
        // and carrying what a launch's environment would otherwise refuse.
        let guids = (0..<AppleMessagesChatScope.maximumChats).map { index -> String in
            let head = "any;-;${HOME}`id` \(index) "
            return head + String(repeating: "\u{E9}", count: (AppleMessagesChatScope.maximumGUIDBytes - head.utf8.count) / 2)
        }
        let chats = AppleMessagesChatScope(guids: guids)
        #expect(chats.isValid && guids.allSatisfy { $0.utf8.count > AppleMessagesChatScope.maximumGUIDBytes - 2 })
        let server = try fixture.preparation().server(for: messagesLaunch().reading(chats), profileURL: nil,
            temporaryDirectoryURL: FileManager().temporaryDirectory,
            fence: FenceProxyResource(interpreterCandidateURLs: [URL(fileURLWithPath: "/bin/sh")]))
        let value = try #require(server.environment[AppleMessagesChatScope.environmentKey])
        let decoded = try JSONDecoder().decode([String].self, from: try #require(Data(base64Encoded: value)))
        #expect(decoded == chats.guids)
        #expect(server.chatScope == chats)
    }

    /// The whole way from the switch to the server, on the real store and the
    /// real launch service: the list the user named is the list the server gets.
    @Test("From the store to the launch: a bot's server reads its own chats, and another bot's reads none")
    func theStoresListIsTheServersList() async throws {
        let fixture = try MessagesFixture(); defer { fixture.remove() }
        let identity = try ConnectorIdentity(id: "openbots:apple-messages:apple-messages",
                                             digest: String(repeating: "c", count: 64))
        let store = ConnectorAccessStore(repository: MessagesMemoryRepository(), catalog: MessagesOnlyCatalog(
            connector: ConfiguredConnector(
                definition: .init(identity: identity, serverName: "apple-messages", pluginName: "OpenBots Next",
                                  transport: .stdio),
                launch: messagesLaunch())))
        let fence = FenceProxyResource(interpreterCandidateURLs: [URL(fileURLWithPath: "/bin/sh")])
        let service = ConnectorLaunchService(store: store, preparations: [fixture.preparation(fence: fence)],
                                             profileRootURL: fixture.root.appendingPathComponent("Profiles.noindex"),
                                             temporaryDirectoryURL: fixture.root, fence: fence)
        let named = TeammateID(UUID()), other = TeammateID(UUID())
        try await store.restore()
        try await store.setAppEnabled(true)
        for bot in [named, other] { try await store.setBotEnabled(true, identity: identity, teammateID: bot) }
        try await store.setMessagesChats(["any;-;+33612345678", "any;+;chat123456789012345678"], teammateID: named)

        let mine = try #require(await service.connectorAccess(teammateID: named, runID: UUID())?.servers.first)
        let theirs = try #require(await service.connectorAccess(teammateID: other, runID: UUID())?.servers.first)
        #expect(mine.chatScope == AppleMessagesChatScope(guids: ["any;-;+33612345678", "any;+;chat123456789012345678"]))
        #expect(mine.environment[AppleMessagesChatScope.environmentKey] == mine.chatScope?.environmentValue)
        #expect(theirs.chatScope == AppleMessagesChatScope(guids: []))
        #expect(theirs.environment[AppleMessagesChatScope.environmentKey]
                == AppleMessagesChatScope(guids: []).environmentValue)
        #expect(await service.messagesChats(teammateID: named) == mine.chatScope)
    }

    @Test("A history this app can open reads ready")
    func aReadableHistoryIsReady() throws {
        let fixture = try MessagesFixture(); defer { fixture.remove() }
        #expect(fixture.preparation().availability(for: messagesLaunch()) == .ready)
    }

    /// Full Disk Access never raises a prompt. A row that read "ready" without
    /// it would switch on and then fail every read, with nothing on the user's
    /// screen saying where to go — so the badge opens the file itself.
    @Test("A history this app cannot open reads needs setup and names the pane to open")
    func anUnreadableHistoryNamesFullDiskAccess() throws {
        let fixture = try MessagesFixture(history: .unreadable); defer { fixture.remove() }
        // The fixture's own guard: if this process could still open the file
        // (running as root, say), the test would prove nothing.
        #expect(AppleMessagesConnectorPreparation.databaseOpenError(fixture.database) != 0)
        let availability = try #require(fixture.preparation().availability(for: messagesLaunch()))
        #expect(availability.badge == "needs setup")
        let reason = try #require(availability.reason)
        #expect(reason.contains("Full Disk Access"))
        #expect(reason.contains("Privacy & Security"))
        #expect(reason.contains("OpenBots Next"))
        #expect(reason.contains("never asks"))
        // Needs setup is not a dead switch: the user can grant the row now and the
        // permission afterwards.
        #expect(availability.canBeEnabled)
    }

    @Test("No history file at all reads needs setup and still names the pane")
    func aMissingHistoryIsNeedsSetup() throws {
        let fixture = try MessagesFixture(history: .missing); defer { fixture.remove() }
        let availability = try #require(fixture.preparation().availability(for: messagesLaunch()))
        #expect(availability.badge == "needs setup")
        #expect(try #require(availability.reason).contains("Full Disk Access"))
    }

    @Test("The launch does not wait for the permission: the server itself says what to turn on")
    func theLaunchDoesNotRequireTheHistory() throws {
        let fixture = try MessagesFixture(history: .unreadable); defer { fixture.remove() }
        let server = try fixture.preparation().server(for: messagesLaunch(), profileURL: nil,
            temporaryDirectoryURL: FileManager().temporaryDirectory,
            fence: FenceProxyResource(interpreterCandidateURLs: [URL(fileURLWithPath: "/bin/sh")]))
        #expect(server.role == .appleMessages)
    }

    @Test("A build without the server says so, and cannot be switched on")
    func aMissingServerIsUnavailable() throws {
        let fixture = try MessagesFixture(); defer { fixture.remove() }
        let preparation = fixture.preparation(scriptURL: nil)
        #expect(throws: AppleMessagesConnectorPreparation.Failure.scriptMissing) {
            try preparation.resolve(messagesLaunch())
        }
        let availability = try #require(preparation.availability(for: messagesLaunch()))
        #expect(!availability.canBeEnabled)
        #expect(try #require(availability.reason).contains("missing the Messages connector"))
    }

    @Test("No Messages on the Mac is unavailable rather than a launch that fails inside a turn")
    func noMessagesIsUnavailable() throws {
        let fixture = try MessagesFixture(installApplication: false); defer { fixture.remove() }
        let preparation = fixture.preparation()
        #expect(throws: AppleMessagesConnectorPreparation.Failure.applicationMissing) {
            try preparation.resolve(messagesLaunch())
        }
        let availability = try #require(preparation.availability(for: messagesLaunch()))
        #expect(availability == .unavailable("Messages is not installed on this Mac."))
    }

    @Test("No node is a needs-setup answer, and a fence that cannot run stops the launch")
    func noNodeAndNoFence() throws {
        let fixture = try MessagesFixture(); defer { fixture.remove() }
        let noNode = fixture.preparation(interpreters: [])
        #expect(throws: AppleMessagesConnectorPreparation.Failure.interpreterMissing) {
            try noNode.resolve(messagesLaunch())
        }
        #expect(try #require(noNode.availability(for: messagesLaunch())).badge == "needs setup")
        // Fail closed: no shim means no launch, never an unfenced one.
        let noFence = fixture.preparation(fence: FenceProxyResource(scriptURL: nil))
        #expect(try #require(noFence.availability(for: messagesLaunch())).canBeEnabled == false)
        #expect(throws: AppleMessagesConnectorPreparation.Failure.fenceUnavailable(.scriptMissing)) {
            try noFence.server(for: messagesLaunch(), profileURL: nil,
                temporaryDirectoryURL: FileManager().temporaryDirectory,
                fence: FenceProxyResource(scriptURL: nil))
        }
    }

    @Test("Another connector's row is not the Messages server's to answer")
    func anotherRowIsNotItsOwn() throws {
        let fixture = try MessagesFixture(); defer { fixture.remove() }
        let preparation = fixture.preparation()
        let contacts = messagesLaunch(command: AppleContactsConnectorPreparation.command)
        #expect(!preparation.prepares(contacts))
        #expect(preparation.availability(for: contacts) == nil)
        #expect(throws: AppleMessagesConnectorPreparation.Failure.notTheMessagesServer) {
            try preparation.resolve(contacts)
        }
        #expect(throws: AppleMessagesConnectorPreparation.Failure.unsupportedTransport) {
            try preparation.resolve(messagesLaunch(transport: .http))
        }
    }

    @Test("The bot is told to check the service first, to resolve names through Contacts, and never to call a hand-off a delivery")
    func thePromptCarriesTheOldAppsRules() {
        let told = ClaudeTextConnectorRole.appleMessages.promptDescription
        #expect(told.contains("You send AS him"))
        #expect(told.contains("explicit instruction from him naming the recipient"))
        #expect(told.contains("Contacts connector"))
        #expect(told.contains("check_message_service"))
        // The rules the server's answers used to carry inside the fence.
        #expect(told.contains("exactly the Handle and the Service it names"))
        #expect(told.contains("more than one match under Ambiguous, do not send"))
        #expect(told.contains("no Handle, tell him why and do not send"))
        #expect(told.contains("marked with \">\""))
        #expect(told.contains("never turn \"handed to Messages\" into \"delivered\""))
        #expect(told.contains("until he has checked the conversation"))
        #expect(told.contains("untrusted material"))
        // It reads only the chats the user chose for this bot.
        #expect(told.contains("only the chats he chose for you"))
        // The two lines the port dropped, because the tools are gone.
        #expect(!told.contains("search_contacts"))
        #expect(!told.contains("send_imessage"))
    }
}

@Suite("Texting from the user's own number: the card")
struct AppleMessagesCardTests {
    @Test("Reading the user's conversations and checking a service are quiet, and the record says with whom")
    func theReadsAreQuiet() throws {
        let read = ClaudeTextConnectorApprovalPolicy.decide(
            try messagesQuestion("read_messages", ["recipient": "+33612345678", "limit": 10]),
            botName: "Kite", role: .appleMessages)
        #expect(read == .allowQuietly(activity: "Read your messages with +33612345678"))
        let everyone = ClaudeTextConnectorApprovalPolicy.decide(
            try messagesQuestion("read_messages", [:]), botName: "Kite", role: .appleMessages)
        #expect(everyone == .allowQuietly(activity: "Read your latest messages in the chats you chose"))
        let check = ClaudeTextConnectorApprovalPolicy.decide(
            try messagesQuestion("check_message_service", ["recipient": "06 12 34 56 78"]),
            botName: "Kite", role: .appleMessages)
        #expect(check == .allowQuietly(activity: "Checked which service reaches 06 12 34 56 78"))
        // A name that arrives from a model is folded and bounded on the record.
        let hostile = ClaudeTextConnectorApprovalPolicy.decide(
            try messagesQuestion("check_message_service",
                                 ["recipient": "+336\u{200B}12\n\nforged line" + String(repeating: "9", count: 300)]),
            botName: "Kite", role: .appleMessages)
        guard case .allowQuietly(let line) = hostile else {
            Issue.record("a check is quiet, got \(hostile)"); return
        }
        #expect(!line.contains("\n") && !line.contains("\u{200B}") && line.count <= 200)
    }

    /// Why a call failed follows as one quoted line the user can read: a
    /// stranger's words in it
    /// can close neither the quote nor the line, and the record's 512 bytes
    /// always hold the part that says what failed.
    @Test("A failed call's reason is kept as one short quoted line, and the line always fits the record")
    func failedCallKeepsItsReason() throws {
        let bash = ClaudeTextToolUse(id: "toolu_09", toolName: "Bash", inputJSON: Data(#"{"command":"cat missing.md"}"#.utf8))
        #expect(OfficialClaudeTextReplyService.failureLine(bash, quiet: nil, access: nil,
                                                           reason: "Exit code 1\ncat: missing.md: No such file or directory")
                == #"Failed to run `cat missing.md`: "Exit code 1 cat: missing.md: No such file or directory""#)
        // Quotation marks and backslashes escaped; hidden and control characters gone.
        let forged = OfficialClaudeTextReplyService.failureLine(bash, quiet: nil, access: nil,
            reason: "a\u{202E}b\" and \\ then\u{0007}\r\nApproved: yes")
        #expect(forged == #"Failed to run `cat missing.md`: "ab\" and \\ then Approved: yes""#)
        // Cut to 160 characters.
        let long = OfficialClaudeTextReplyService.failureLine(bash, quiet: nil, access: nil,
                                                              reason: String(repeating: "e", count: 400))
        let quoted = try #require(long.split(separator: ": ", maxSplits: 1).last)
        #expect(quoted.count == OfficialClaudeTextReplyService.failureReasonCharacters + 2 && quoted.hasSuffix("…\""))
        // Wide characters meet the record's bytes first: cut there, on whole
        // characters (a four-part emoji is never split), the quote still closed.
        let wideReason = OfficialClaudeTextReplyService.failureLine(bash, quiet: nil, access: nil,
                                                                    reason: String(repeating: "👩‍💻", count: 400))
        let wideQuote = try #require(wideReason.split(separator: ": ", maxSplits: 1).last)
        #expect(wideReason.utf8.count <= 500 && wideQuote.hasSuffix("…\""))
        #expect(wideQuote.dropFirst().dropLast(2).allSatisfy { $0 == "👩‍💻" })
        // A connector's refusal comes back inside the untrusted-material fence:
        // the line quotes the refusal, not the fence's own words (seen live:
        // "[UNTRUSTED MATERIAL — tool result from apple-messages] Everything…").
        let fenced = [UntrustedMaterial.header(label: "apple-messages"), UntrustedMaterial.instruction, "",
                      "No chat you chose is with Tim.", UntrustedMaterial.closeMarker].joined(separator: "\n")
        #expect(OfficialClaudeTextReplyService.failureLine(bash, quiet: nil, access: nil, reason: fenced)
                == #"Failed to run `cat missing.md`: "No chat you chose is with Tim.""#)
        // No words, or only hidden ones: the line as it always was.
        #expect(OfficialClaudeTextReplyService.failureLine(bash, quiet: nil, access: nil, reason: " \u{200B} ")
                == "Failed to run `cat missing.md`")
        // A line already near the limit keeps what failed and gives up the reason.
        let path = String(repeating: "x", count: 480)
        let wide = ClaudeTextToolUse(id: "toolu_10", toolName: "Bash", inputJSON: Data(#"{"command":"\#(path)"}"#.utf8))
        let kept = OfficialClaudeTextReplyService.failureLine(wide, quiet: nil, access: nil, reason: "Exit code 1")
        #expect(kept.utf8.count <= 512 && kept.hasPrefix("Failed to run"))
    }

    /// A read the server refused — a chat outside the ones the user chose, or none
    /// chosen — comes back as a failed call, and the record says the read in
    /// its own words did not happen, instead of "Failed to use read messages".
    @Test("A read that did not happen is on the record in the read's own words")
    func aReadThatDidNotHappenIsOnTheRecord() throws {
        let use = ClaudeTextToolUse(id: "toolu_07", toolName: "mcp__\(messagesServerKey)__read_messages",
                                    inputJSON: Data("{}".utf8))
        #expect(OfficialClaudeTextReplyService.failureLine(use, quiet: "Read your messages with +33612345678",
                                                           access: nil)
                == "Failed to read your messages with +33612345678")
        #expect(OfficialClaudeTextReplyService.failureLine(use, quiet: "Read your latest messages in the chats you chose",
                                                           access: nil)
                == "Failed to read your latest messages in the chats you chose")
        #expect(OfficialClaudeTextReplyService.failureLine(use, quiet: "Checked which service reaches +3361",
                                                           access: nil)
                == "Failed to check which service reaches +3361")
        // With no quiet line of its own, or one whose verb cannot be turned,
        // the call reads as it always did; and a built-in tool keeps its line.
        // ("Listed …" was once such a verb; every quiet line's verb is now
        // turned, ConnectorFailureLineTests.)
        let before = "Failed to " + OfficialClaudeTextReplyService.attemptLine(use, access: nil)
        #expect(OfficialClaudeTextReplyService.failureLine(use, quiet: nil, access: nil) == before)
        #expect(OfficialClaudeTextReplyService.failureLine(use, quiet: "Pondered the OpenBots Google calendars",
                                                           access: nil) == before)
        let bash = ClaudeTextToolUse(id: "toolu_08", toolName: "Bash",
                                     inputJSON: Data(#"{"command":"cat missing.md"}"#.utf8))
        #expect(OfficialClaudeTextReplyService.failureLine(bash, quiet: "Ran `cat missing.md` in Kite's folder",
                                                           access: nil) == "Failed to run `cat missing.md`")
    }

    @Test("A send is never quiet: the card names the recipient and the service and shows the exact words")
    func theSendCardShowsTheText() throws {
        let text = "Running late.\n\n  Be there at 8 — sorry! 👩‍💻"
        let card = try sendCard(["recipient": "+33612345678", "service": "iMessage", "text": text])
        #expect(card.title == "Send a text as you")
        #expect(card.kind == .send)
        #expect(card.target == "+33612345678 on iMessage")
        #expect(sameScalars(card.detail, "It goes out from your own number and cannot be taken back. "
                            + "Messages may still send it on another service.\n\n" + text))
        // Written before the user answers, so it says what was asked.
        #expect(card.activity == "Asked to text +33612345678")
        #expect(card.turnScope == nil, "a text is asked about every time")
    }

    /// The service on the card is what the send asks Messages for, not a
    /// promise: into a conversation Messages already keeps, `send … to chat id`
    /// takes no service and Messages picks one itself, and an RCS text with no
    /// conversation goes through the SMS relay. Every card says so.
    @Test("Every card says Messages may still send it on another service, and an RCS card names SMS")
    func everyCardSaysTheServiceIsARequest() throws {
        let rcs = try sendCard(["recipient": "+33612345678", "service": "RCS", "text": "hi"])
        #expect(sameScalars(rcs.detail, "It goes out from your own number and cannot be taken back. "
            + "Messages may still send it as SMS.\n\nhi"))
        for service in ["iMessage", "SMS"] {
            let card = try sendCard(["recipient": "someone@example.com", "service": service, "text": "hi"])
            #expect(sameScalars(card.detail, "It goes out from your own number and cannot be taken back. "
                + "Messages may still send it on another service.\n\nhi"), "\(service)")
            #expect(card.target == "someone@example.com on \(service)")
        }
    }

    @Test("A long text is on the card whole, never cut at the mail card's six hundred characters")
    func aLongTextIsNotCut() throws {
        let text = (1...25).map { "Line \($0) of a long text that they have to be able to read in full." }
            .joined(separator: "\n")
        #expect(text.unicodeScalars.count <= AppleMessagesSendProposal.maximumTextScalars)
        let card = try sendCard(["recipient": "+33612345678", "service": "SMS", "text": text])
        #expect(card.detail.count > 600)
        #expect(card.detail.unicodeScalars.suffix(text.unicodeScalars.count).elementsEqual(text.unicodeScalars))
        #expect(!card.detail.contains("\u{2026}"))
    }

    /// The approvals record keeps `String(detail.prefix(2_000))`, measured in
    /// characters, and a character is never fewer than one scalar. So the worst
    /// card is the longest heading, the longest recipient and a text of the
    /// maximum length in one-scalar characters, and it has to survive the
    /// record whole — pinned rather than left to the arithmetic in a comment.
    @Test("The longest card any accepted input can build fits the approvals record whole")
    func theWorstCaseCardFitsTheRecord() throws {
        // 64 + 1 + (60 + 1 + 60 + 1 + 60 + 1 + 6): exactly the longest address allowed.
        let recipient = String(repeating: "a", count: 64) + "@"
            + (0..<3).map { _ in String(repeating: "b", count: 60) }.joined(separator: ".") + ".exampl"
        #expect(recipient.count == AppleMessagesSendProposal.maximumRecipientLength)
        // The most lines an accepted text can have, which is the longest count
        // the heading can print: one-letter lines with one blank line between
        // each pair, the first line padded to the limit.
        let mostLines = "aaa" + String(repeating: "\n\na", count: 599)
        #expect(mostLines.unicodeScalars.count == AppleMessagesSendProposal.maximumTextScalars)
        for text in [String(repeating: "x", count: AppleMessagesSendProposal.maximumTextScalars), mostLines] {
            for service in AppleMessagesSendProposal.services {
                let card = try sendCard(["recipient": recipient, "service": service, "text": text])
                #expect(card.detail.unicodeScalars.count <= 2_000,
                        Comment(rawValue: "the \(service) detail is \(card.detail.unicodeScalars.count) scalars"))
                #expect(sameScalars(String(card.detail.prefix(2_000)), card.detail))
                let record = try ApprovalRequest(id: ApprovalID(UUID()), teammateID: TeammateID(UUID()),
                    conversationID: ConversationID(UUID()), action: card.kind,
                    exactTargetSummary: String(card.detail.prefix(2_000)),
                    consequenceSummary: String([card.title, card.target].joined(separator: " · ").prefix(2_000)),
                    fingerprint: ApprovalFingerprint(String(repeating: "f", count: 64)), requestedAt: Date())
                // Equal, not merely ending in the text: the record trims both
                // ends of what it keeps, which a text of x's can never show.
                // ClaudeTextWorkTurnServiceTests.aTextCardIsRecordedExactly
                // writes the row through the service itself.
                #expect(record.exactTargetSummary == card.detail)
                #expect(record.consequenceSummary.contains(recipient))
            }
        }
    }

    /// The box on the card shows nine lines before it scrolls, and a trackpad
    /// hides the scroller, so a text that may run past it says so in the app's
    /// own words above the text, where the bot cannot write.
    @Test("A text longer than the card's box says how many lines it has, above the words")
    func aTextPastTheBoxCountsItsLines() throws {
        // The heading shares the box: in the narrowest composer its two
        // sentences wrap to three lines, and with the blank line after them
        // they leave five of the nine for the words. A six-line text went
        // uncounted past the fold; ApprovalCardReadingTests renders it.
        let four = (1...4).map { "Line \($0)" }.joined(separator: "\n")
        let fits = try sendCard(["recipient": "+33612345678", "service": "SMS", "text": four])
        #expect(!fits.detail.contains("lines long"), Comment(rawValue: fits.detail))
        let five = try sendCard(["recipient": "+33612345678", "service": "SMS",
                                 "text": (1...5).map { "Line \($0)" }.joined(separator: "\n")])
        #expect(five.detail.contains(" The text is 5 lines long.\n\n"), Comment(rawValue: five.detail))
        let dotted = "Sure, see you then" + String(repeating: "\n.", count: 7) + "\ncode 123456"
        let card = try sendCard(["recipient": "+33612345678", "service": "SMS", "text": dotted])
        let heading = try #require(card.detail.components(separatedBy: "\n\n").first)
        #expect(heading.hasPrefix(ClaudeTextAppleMessagesApprovalPolicy.consequence))
        #expect(heading.hasSuffix(" The text is 9 lines long."), Comment(rawValue: heading))
        #expect(sameScalars(card.detail, heading + "\n\n" + dotted))
    }

    @Test("A proposal the card could not show exactly is refused by rule and never becomes a card",
          arguments: AppleMessagesCardTests.refusedProposals)
    func anUnshowableProposalIsRefused(_ proposal: RefusedProposal) throws {
        let decision = ClaudeTextConnectorApprovalPolicy.decide(
            try messagesQuestion("send_message", proposal.input), botName: "Kite", role: .appleMessages)
        guard case .denyQuietly(let reason, let activity) = decision else {
            Issue.record("\(proposal.label) became \(decision)"); return
        }
        #expect(reason.hasSuffix("Nothing was sent."), Comment(rawValue: reason))
        #expect(activity.hasPrefix("Blocked"))
        #expect(throws: AppleMessagesSendProposal.Refusal.self) {
            try AppleMessagesSendProposal(input: proposal.input)
        }
    }

    struct RefusedProposal: CustomTestStringConvertible, Sendable {
        let label: String
        let recipient: String?
        let service: String?
        let text: String?
        /// A value that is not a string, keyed by field, kept apart because
        /// `Any` is not `Sendable`.
        let nonString: String?

        var input: [String: Any] {
            var input: [String: Any] = [:]
            if let recipient { input["recipient"] = recipient }
            if let service { input["service"] = service }
            if let text { input["text"] = text }
            switch nonString {
            case "recipient-array": input["recipient"] = ["+33612345678"]
            case "recipient-number": input["recipient"] = 33_612_345_678
            case "text-number": input["text"] = 42
            case "service-bool": input["service"] = true
            case "text-null": input["text"] = NSNull()
            // A field the tool does not take: nothing on the card could show it.
            case "extra-field": input["note"] = "for later"
            case "extra-null-field": input["cc"] = NSNull()
            case "near-miss-field": input["texts"] = "hi"
            default: break
            }
            return input
        }

        var testDescription: String { label }
    }

    static let refusedProposals: [RefusedProposal] = {
        func text(_ label: String, _ value: String) -> RefusedProposal {
            RefusedProposal(label: label, recipient: "+33612345678", service: "SMS", text: value, nonString: nil)
        }
        func recipient(_ label: String, _ value: String) -> RefusedProposal {
            RefusedProposal(label: label, recipient: value, service: "SMS", text: "hi", nonString: nil)
        }
        func service(_ label: String, _ value: String) -> RefusedProposal {
            RefusedProposal(label: label, recipient: "+33612345678", service: value, text: "hi", nonString: nil)
        }
        func odd(_ label: String) -> RefusedProposal {
            RefusedProposal(label: label, recipient: "+33612345678", service: "SMS", text: "hi", nonString: label)
        }
        return [
            RefusedProposal(label: "no recipient", recipient: nil, service: "SMS", text: "hi", nonString: nil),
            RefusedProposal(label: "no service", recipient: "+33612345678", service: nil, text: "hi", nonString: nil),
            RefusedProposal(label: "no text", recipient: "+33612345678", service: "SMS", text: nil, nonString: nil),
            odd("recipient-array"), odd("recipient-number"), odd("text-number"), odd("service-bool"),
            odd("text-null"), odd("extra-field"), odd("extra-null-field"), odd("near-miss-field"),
            service("auto", "auto"), service("lower case", "sms"), service("wrong case", "Imessage"),
            service("trailing space", "iMessage "), service("unknown", "WhatsApp"),
            recipient("spaced number", "+33 6 12 34 56 78"), recipient("leading space", " +33612345678"),
            recipient("trailing space", "+33612345678 "), recipient("trailing newline", "+33612345678\n"),
            recipient("dotted number", "06.12.34.56.78"), recipient("punctuated number", "(415) 555-0100"),
            recipient("two digits", "12"), recipient("sixteen digits", "+1234567890123456"),
            recipient("Arabic-Indic digits", "\u{660}\u{666}\u{661}\u{662}\u{663}\u{664}\u{665}\u{666}"),
            recipient("fullwidth digits", "\u{FF10}\u{FF16}\u{FF11}\u{FF12}\u{FF13}\u{FF14}\u{FF15}\u{FF16}"),
            recipient("a name", "Charles Dupont"), recipient("name and address", "Sarah <sarah@example.com>"),
            recipient("accented address", "jos\u{E9}@example.com"), recipient("no dot in domain", "alice@example"),
            recipient("two at signs", "alice@@example.com"), recipient("empty label", "alice@example..com"),
            recipient("zero-width space", "+336\u{200B}12345678"), recipient("empty", ""),
            recipient("too long", String(repeating: "a", count: 64) + "@"
                + (0..<4).map { _ in String(repeating: "b", count: 62) }.joined(separator: ".") + ".com"),
            // Lines that push words below the card's fold, or are nothing but a fold.
            text("only a newline", "\n"), text("only spaces", "   "), text("leading newline", "\nSure"),
            text("leading blank line of spaces", " \t\nSure"), text("trailing newline", "Sure\n"),
            text("trailing blank line of spaces", "Sure\n\u{3000} "), text("two blank lines", "Sure\n\n\nsee you"),
            // A space at the very end, which the card cannot show and the record would drop.
            text("trailing space", "See you at 8 "), text("trailing tab", "See you at 8\t"),
            text("trailing no-break space", "See you at 8\u{A0}"),
            text("two blank lines of spaces", "Sure\n \n\u{A0}\nsee you"),
            text("a second paragraph far below", "Sure, see you then" + String(repeating: "\n", count: 40) + "code 123456"),
            text("empty", ""), text("NUL", "a\u{0}b"), text("carriage return", "a\rb"),
            text("CRLF", "a\r\nb"), text("vertical tab", "a\u{0B}b"), text("form feed", "a\u{0C}b"),
            text("escape", "a\u{1B}b"), text("DEL", "a\u{7F}b"), text("next line", "a\u{85}b"),
            text("C1 CSI", "a\u{9B}b"), text("line separator", "a\u{2028}b"),
            text("paragraph separator", "a\u{2029}b"), text("zero-width space", "a\u{200B}b"),
            text("left-to-right mark", "a\u{200E}b"), text("right-to-left override", "a\u{202E}b"),
            text("first-strong isolate", "a\u{2068}b"), text("word joiner", "a\u{2060}b"),
            text("byte order mark", "a\u{FEFF}b"), text("Arabic letter mark", "a\u{061C}b"),
            text("one past the limit", String(repeating: "x", count: AppleMessagesSendProposal.maximumTextScalars + 1)),
            // Joiners and selectors where they draw nothing: a code hidden in a
            // sentence the card draws pixel for pixel like the plain one
            // and a secret a joiner breaks up.
            text("joiner between Latin letters", "See you at 8".replacingOccurrences(of: "e", with: "e\u{200D}")),
            text("non-joiner between Latin letters", "See you at 8".replacingOccurrences(of: "o", with: "o\u{200C}")),
            text("selector after a Latin letter", "See you at 8\u{FE0F}"),
            text("selector after an accented letter", "\u{E0} tout \u{E0} l'heure\u{FE0E}"),
            text("joiner inside a password", "hun\u{200D}ter22"),
            text("non-joiner beside a digit", "code 4\u{200C}81516"),
            text("selector after a digit with no keycap", "8\u{FE0F} o'clock"),
            text("joiner between an emoji and a letter", "\u{1F600}\u{200D}b"),
            // A selector where it changes no drawing: after a character already
            // drawn as emoji, or after one drawn as text.
            text("selector after an emoji already drawn as one", "party \u{1F600}\u{FE0F} time"),
            text("text selector after a text-drawn symbol", "\u{A9}\u{FE0E} 2026 Acme"),
            text("text selector after a trademark sign", "Acme\u{2122}\u{FE0E}"),
            text("text selector after a square", "\u{25AA}\u{FE0E} milk"),
            // Characters that take up space and draw nothing at all.
            text("object replacement character", "a\u{FFFC}b"), text("blank braille pattern", "a\u{2800}b"),
            // Default-ignorable characters the card draws as nothing.
            text("soft hyphen", "a\u{AD}b"), text("combining grapheme joiner", "a\u{34F}b"),
            text("Hangul filler", "OK\u{3164}"), text("halfwidth Hangul filler", "OK\u{FFA0}"),
            text("Hangul choseong filler", "OK\u{115F}"), text("Mongolian variation selector", "a\u{180B}b"),
            text("inhibit symmetric swapping", "a\u{206A}b"), text("unassigned U+2065", "a\u{2065}b"),
            text("variation selector 1", "a\u{FE00}b"), text("unassigned U+FFF0", "a\u{FFF0}b"),
            text("shorthand format overlap", "a\u{1BCA0}b"), text("musical begin beam", "a\u{1D173}b"),
            text("language tag", "a\u{E0001}b"), text("variation selector 17", "a\u{E0100}b"),
            text("unassigned tag block end", "a\u{E0FFF}b"),
            text("interlinear annotation anchor", "a\u{FFF9}b"), text("interlinear annotation terminator", "a\u{FFFB}b"),
            // A code spelled in tag characters after an innocent word: the card reads "OK".
            text("tag-spelled code", "OK" + "123456".unicodeScalars.map { String(Unicode.Scalar($0.value + 0xE0000)!) }
                .joined()),
            // Tags that spell no flag, or an unfinished one.
            text("unknown subdivision flag", "\u{1F3F4}\u{E0067}\u{E0062}\u{E0078}\u{E0079}\u{E007A}\u{E007F}"),
            text("flag without its cancel tag", "\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}"),
            text("tags with no black flag", "\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}"),
            // Joiners and selectors out of their place.
            text("joiner alone", "\u{200D}"), text("joiner first", "\u{200D}a"), text("joiner last", "a\u{200D}"),
            text("joiner after a space", "a \u{200D}b"), text("joiner before a space", "a\u{200D} b"),
            text("two joiners", "a\u{200D}\u{200D}b"), text("non-joiner then joiner", "a\u{200C}\u{200D}b"),
            text("joiner before a newline", "a\u{200D}\nb"), text("non-joiner after a newline", "a\n\u{200C}b"),
            text("selector alone", "\u{FE0F}"), text("selector after a space", "a \u{FE0F}"),
            text("selector after a newline", "a\n\u{FE0E}"), text("two selectors", "\u{2764}\u{FE0F}\u{FE0F}"),
        ]
    }()

    /// Unicode 16's Default_Ignorable_Code_Point, copied from
    /// DerivedCoreProperties.txt on its own, so the rule is checked against
    /// Unicode rather than against itself.
    static let unicodeDefaultIgnorable: [ClosedRange<UInt32>] = [
        0x00AD...0x00AD, 0x034F...0x034F, 0x061C...0x061C, 0x115F...0x1160, 0x17B4...0x17B5,
        0x180B...0x180F, 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x206F, 0x3164...0x3164,
        0xFE00...0xFE0F, 0xFEFF...0xFEFF, 0xFFA0...0xFFA0, 0xFFF0...0xFFF8, 0x1BCA0...0x1BCA3,
        0x1D173...0x1D17A, 0xE0000...0xE0FFF,
    ]

    /// The card draws every one of these as nothing, so each is a place to hide
    /// words the user approves without reading: a code spelled in tag characters
    /// after "OK" reads "OK". Four of them are content in their place, and only
    /// there — the two joiners between visible characters, the two presentation
    /// selectors after one — and the tag characters spell the three flags.
    @Test("Every character Unicode calls default-ignorable is refused out of its place, and the interlinear annotations everywhere")
    func everyInvisibleCharacterIsRefusedOutOfPlace() throws {
        var values = Set<UInt32>(0xFFF9...0xFFFB)
        for range in Self.unicodeDefaultIgnorable { values.formUnion(range) }
        // And whatever this toolchain's own Unicode tables add.
        for value in UInt32(0)...0x10FFFF {
            if let scalar = Unicode.Scalar(value), scalar.properties.isDefaultIgnorableCodePoint { values.insert(value) }
        }
        #expect(values.count >= 4_177)
        // Between two Latin letters all four of these are refused now, so none is
        // exempt from that place any more.
        let contextual: Set<UInt32> = []
        var passed: [String] = []
        for value in values.sorted() {
            let scalar = try #require(Unicode.Scalar(value))
            var texts = ["\(scalar)", "a \(scalar) b", "a\n\(scalar)"]
            if !contextual.contains(value) { texts.append("a\(scalar)b") }
            for text in texts {
                do {
                    _ = try AppleMessagesSendProposal(input: ["recipient": "+33612345678", "service": "SMS", "text": text])
                    passed.append(text.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " "))
                } catch AppleMessagesSendProposal.Refusal.refusedCharacter(let refused) {
                    if refused != value { passed.append(String(format: "U+%04X named as U+%04X", value, refused)) }
                }
            }
        }
        #expect(passed.isEmpty, Comment(rawValue: "\(passed.count) passed the card: \(passed.prefix(12))"))
    }

    /// Texts whose invisible characters are content, each in its place. The
    /// wire sweep sends every one of them through the shipped server too.
    static let invisibleInPlace: [String] = [
        "\u{1F469}\u{200D}\u{1F4BB} standup", "\u{645}\u{6CC}\u{200C}\u{631}\u{648}\u{645}",
        "\u{2764}\u{FE0F}", "\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}",
        // A joiner whose left neighbour is a presentation selector: the couple,
        // the heart on fire, the rainbow flag, the eye in a speech bubble.
        "\u{1F469}\u{200D}\u{2764}\u{FE0F}\u{200D}\u{1F468}", "\u{2764}\u{FE0F}\u{200D}\u{1F525}",
        "\u{1F3F3}\u{FE0F}\u{200D}\u{1F308}", "\u{1F441}\u{FE0F}\u{200D}\u{1F5E8}\u{FE0F}",
        // Skin tones inside a joined sequence, and a keycap.
        "\u{1F9D1}\u{1F3FD}\u{200D}\u{1F91D}\u{200D}\u{1F9D1}\u{1F3FB}", "1\u{FE0F}\u{20E3}",
        // The other two flags tag characters may spell.
        "\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}",
        "\u{1F3F4}\u{E0067}\u{E0062}\u{E0077}\u{E006C}\u{E0073}\u{E007F}",
        // A joiner after a virama, and an emoji asked to be drawn as text.
        "\u{915}\u{94D}\u{200D}\u{937}", "\u{1F600}\u{FE0E}",
    ]

    @Test("What looks invisible but hides nothing passes: joiners, emoji selectors, tabs and newlines")
    func contentThatOnlyLooksInvisiblePasses() throws {
        for text in Self.invisibleInPlace + ["a\tb", "a\nb", "caf\u{65}\u{301}",
                     // One blank line between paragraphs, even one of spaces, and an indent.
                     "See you at 8.\n\nBring the keys.", "a\n \u{A0}\nb", "  indented",
                     String(repeating: "x", count: AppleMessagesSendProposal.maximumTextScalars)] {
            let card = try sendCard(["recipient": "+33612345678", "service": "SMS", "text": text])
            #expect(card.detail.unicodeScalars.suffix(text.unicodeScalars.count).elementsEqual(text.unicodeScalars),
                    Comment(rawValue: text.debugDescription))
        }
        // Both shapes of recipient, at the edges of what they allow.
        for recipient in ["123", "+123456789012345", "a@b.example", "first.last+tag%x-y@sub-domain.department.example"] {
            _ = try sendCard(["recipient": recipient, "service": "iMessage", "text": "hi"])
        }
    }

    /// The wire sweep in `AppleMessagesScriptTests` once could not carry these
    /// three: a raw U+2028 or U+2029 split the server's line-framed protocol,
    /// and a NUL the rule let through would fail at the spawn looking like a
    /// refusal. It carries all three now, and holds a
    /// refusal to the server's own words; the card's half stays pinned here.
    @Test("The characters the wire sweep once could not carry are refused by the card's rule")
    func theUnsweepableCharactersAreRefused() throws {
        for value: UInt32 in [0x0000, 0x2028, 0x2029] {
            let scalar = try #require(Unicode.Scalar(value))
            #expect(throws: AppleMessagesSendProposal.Refusal.refusedCharacter(value)) {
                try AppleMessagesSendProposal(input: ["recipient": "+33612345678", "service": "SMS",
                                                      "text": "a\(scalar)b"])
            }
        }
    }

    @Test("A secret the user gave counts in a text however it is spelled, and a word that only begins like one does not")
    func aSecretInATextIsFoundWhole() throws {
        func carries(_ text: String, to recipient: String = "+33612345678",
                     secrets: [String] = ["hunter22", "caf\u{E9}-9"]) throws -> Bool {
            ClaudeTextAppleMessagesApprovalPolicy.sendCarriesASecret(
                try JSONSerialization.data(withJSONObject: ["recipient": recipient, "service": "SMS", "text": text]),
                secrets: secrets)
        }
        #expect(try carries("the key is hunter22"))
        // A mark on its last letter makes a different character, not a different secret.
        #expect(try carries("hunter22\u{301} is the key"))
        // A canonically equal spelling is the same secret on the user's screen.
        #expect(try carries("cafe\u{301}-9"))
        #expect(try carries("hello", to: "+33612345678", secrets: ["33612345678"]))
        #expect(try !carries("Count me in for the hunt"))
        #expect(try !carries("Happy hunt\u{2026} see you"))
        #expect(try !carries("abc", secrets: ["abc"]), "shorter than four characters is not blanked, so not counted")
        #expect(ClaudeTextAppleMessagesApprovalPolicy.sendCarriesASecret(Data("not a text".utf8), secrets: []),
                "an input that cannot be read cannot be shown, so it is not sent")
    }

    @Test("A tool the Messages server never announced asks, in Messages' words")
    func anUnknownToolAsks() throws {
        let decision = ClaudeTextConnectorApprovalPolicy.decide(
            try messagesQuestion("delete_conversation", ["recipient": "+33612345678"]),
            botName: "Kite", role: .appleMessages)
        guard case .ask(let card) = decision else {
            Issue.record("an unknown Messages tool must ask, got \(decision)"); return
        }
        #expect(card.title == "Do something in Messages")
        #expect(card.kind == .send)
        #expect(card.detail.contains("does not know what that does"))
        #expect(card.activity.hasPrefix("Asked to"))
    }
}
