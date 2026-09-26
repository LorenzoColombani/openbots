import Foundation
import OpenBotsContent
import OpenBotsDomain
@testable import OpenBotsPersistence
import OpenBotsRuntime
@testable import OpenBotsServices
import Testing

@Suite("A work turn on the chat path: the card asks, the answer reaches the child, the decision is written")
struct ClaudeTextWorkTurnServiceTests {
    @Test("A move asks the user; Approve answers the channel and records the approval")
    func cardApproved() async throws {
        let f = try WorkTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = WorkTurnRunner(question: try f.question(["command": "mv a.txt b.txt"]))
        let service = try f.service(store, runner: runner)
        let progress = WorkTurnProgressLog()
        let turn = Task { await service.sendText(f.submission()) { await progress.append($0) } }
        let approval = try await progress.waitForApproval()
        #expect(approval.title == "Move or rename files with a command")
        #expect(approval.detail == "mv a.txt b.txt" && approval.toolName == "Bash")
        #expect(try await store.approval(id: ApprovalID(approval.id))?.state == .pending)
        #expect(await service.decideApproval(id: approval.id, allow: true))
        #expect(!(await service.decideApproval(id: approval.id, allow: true)), "a card is answered once")
        let result = await turn.value
        #expect(result.outcome == .completed)
        let answers = await runner.answers
        #expect(answers.count == 1)
        #expect(answers.first.map { String(decoding: $0, as: UTF8.self) }?.contains("\"behavior\":\"allow\"") == true)
        #expect(try await store.approval(id: ApprovalID(approval.id))?.state == .approved)
        #expect(await progress.resolved.contains(approval.id))
        // The record: the card and its verdict, readable by conversation.
        let cards = try await store.approvals(conversationID: f.conversationID, limit: 10)
        #expect(cards.map(\.state) == [.approved] && cards.first?.id == ApprovalID(approval.id))
        let lines = try await store.runActivity(conversationID: f.conversationID, limit: 50)
        #expect(lines.map(\.line).contains("Approved: move or rename files with a command"))
        // "Ran" goes on the record once the result is in, after the verdict, never at the ask.
        let texts = lines.map(\.line)
        let approved = try #require(texts.firstIndex(of: "Approved: move or rename files with a command"))
        let ran = try #require(texts.firstIndex(of: "Ran `mv a.txt b.txt`"), "\(texts)")
        #expect(ran > approved && texts.filter { $0.hasPrefix("Ran ") }.count == 1, "\(texts)")
        #expect(lines.allSatisfy { $0.teammateID == f.teammateID })
        let request = try #require(await runner.requests.first)
        #expect(request.grantsWork && request.expectedPermissionMode == "default")
        #expect(request.systemPrompt.contains("You are working on the user's Mac"))
        let access = try f.access()
        #expect(request.systemPrompt.contains(access.workingDirectoryURL.path))
        #expect(!request.systemPrompt.contains("No tools, file access"))
    }

    // A script the bot ran comes back to the user as a file.
    @Test("A script run on an approved card comes back on the reply as a chip, from the bot's folder root; a denied one does not",
          arguments: [true, false])
    func aRunScriptComesBackAsAChip(_ approve: Bool) async throws {
        let f = try WorkTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        try FileManager.default.createDirectory(at: f.ownFolder.appending(path: "Outbox"), withIntermediateDirectories: true)
        try Data("print('hi')".utf8).write(to: f.ownFolder.appending(path: "list_files_by_date.py"))
        let runner = WorkTurnRunner(question: try f.question(["command": "python3 list_files_by_date.py"]))
        let attachments = ConversationAttachmentService(repository: store, messages: store,
            importer: { url, id in
                let data = try Data(contentsOf: url)
                return try StoredAttachmentContent(id: id, byteCount: Int64(data.count),
                    sha256: String(repeating: "c", count: 64), typeIdentifier: "public.python-script",
                    displayName: url.lastPathComponent)
            },
            verifier: { _ in }, location: { _ in throw ConversationAttachmentError.unavailable })
        let service = OfficialClaudeTextReplyService(repository: store, teammates: store, conversations: store,
            messages: store, preparer: WorkTurnPreparer(target: try f.target()), runner: runner,
            appOwnerID: f.appOwner, webAccess: WorkAndMessagesAccess(access: try f.access()),
            approvals: store, deliverables: attachments, activity: store)
        let progress = WorkTurnProgressLog()
        let turn = Task { await service.sendText(f.submission()) { await progress.append($0) } }
        let card = try await progress.waitForApproval()
        #expect(card.title == "Run list_files_by_date.py", "\(card.title)")
        #expect(await service.decideApproval(id: card.id, allow: approve))
        let result = await turn.value
        #expect(result.outcome == .completed)
        let reply = try #require(result.savedReplyMessage)
        var names: [String] = []
        for part in reply.parts {
            if case .attachment(let id) = part.content,
               let asset = try await store.attachment(id: id, conversationID: f.conversationID) { names.append(asset.displayName) }
        }
        #expect(names == (approve ? ["list_files_by_date.py"] : []), "\(reply.parts)")
    }

    // Contacts started hidden by a lookup must not be left running long after
    // the reply ends.
    @Test("Contacts a lookup started is asked to quit when the reply ends; one already open, or no lookup, is left alone",
          arguments: [(false, true, true), (true, true, false), (false, false, false)])
    func contactsALookupStartedIsQuit(_ runningAtStart: Bool, _ looksUp: Bool, _ quits: Bool) async throws {
        let f = try WorkTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let lookup = ClaudeTextToolUse(id: "toolu_c", toolName: "mcp__\(WorkAndMessagesAccess.serverName)__search_contacts",
                                       inputJSON: try f.question(["query": "Charles"]))
        let runner = WorkTurnRunner(question: try f.question(["command": "ls"]), preamble: looksUp ? [.toolUse(lookup)] : [])
        let apps = FakeHiddenApps(running: runningAtStart ? ["com.apple.AddressBook"] : [])
        let service = OfficialClaudeTextReplyService(repository: store, teammates: store, conversations: store,
            messages: store, preparer: WorkTurnPreparer(target: try f.target()), runner: runner,
            appOwnerID: f.appOwner, webAccess: WorkAndMessagesAccess(access: try f.access(), role: .appleContactsRead),
            approvals: store, activity: store, hiddenApps: apps)
        #expect(await service.sendText(f.submission()) { _ in }.outcome == .completed)
        #expect(apps.quitRequests == (quits ? ["com.apple.AddressBook"] : []), "\(apps.quitRequests)")
    }

    // A turn ending must not quit Contacts under another
    // bot's turn still using it, which then never quit it.
    @Test("Contacts a lookup started is left running while another reply with Contacts runs, and quit when the last one ends")
    func contactsIsQuitByTheLastReplyUsingIt() async throws {
        let f = try WorkTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let other = TeammateID(UUID()), otherChat = ConversationID(UUID())
        try await store.provisionDirectChat(teammate: try Teammate(id: other,
            profile: TeammateProfile(displayName: "Kefir", role: "Teammate", detailedInstructions: nil),
            appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 7,
                silhouette: "round", paletteToken: "sky", eyeDialect: "bright",
                nonColorIdentityCue: "single crest", accessibleIdentityDescription: "Round creature with a crest"),
            createdAt: f.date, updatedAt: f.date),
            conversation: Conversation(id: otherChat, kind: .direct(teammateID: other), createdAt: f.date, updatedAt: f.date),
            fixtureGreeting: nil, selectConversation: false)
        let lookup = ClaudeTextToolUse(id: "toolu_c", toolName: "mcp__\(WorkAndMessagesAccess.serverName)__search_contacts",
                                       inputJSON: try f.question(["query": "Charles"]))
        let runner = WorkTurnRunner(question: try f.question(["command": "mv a.txt b.txt"]), preamble: [.toolUse(lookup)])
        let apps = FakeHiddenApps(running: [])
        let service = OfficialClaudeTextReplyService(repository: store, teammates: store, conversations: store,
            messages: store, preparer: WorkTurnPreparer(target: try f.target()), runner: runner,
            appOwnerID: f.appOwner, webAccess: WorkAndMessagesAccess(access: try f.access(), role: .appleContactsRead),
            approvals: store, activity: store, hiddenApps: apps)
        let progress = WorkTurnProgressLog()
        let first = Task { await service.sendText(f.submission()) { await progress.append($0) } }
        let firstCard = try await progress.waitForApproval()
        let second = Task {
            await service.sendText(ClaudeTextTurnSubmission(conversationID: otherChat, teammateID: other,
                userMessageID: MessageID(UUID()), text: "Find Charles.")) { await progress.append($0) }
        }
        let secondCard = try await progress.waitForApproval(count: 2)
        #expect(await service.decideApproval(id: firstCard.id, allow: true))
        #expect(await first.value.outcome == .completed)
        #expect(apps.quitRequests.isEmpty, "the other reply still uses Contacts: \(apps.quitRequests)")
        #expect(await service.decideApproval(id: secondCard.id, allow: true))
        #expect(await second.value.outcome == .completed)
        #expect(apps.quitRequests == ["com.apple.AddressBook"], "\(apps.quitRequests)")
    }

    @Test("Deny answers the channel with a refusal and records the denial; the turn still finishes")
    func cardDenied() async throws {
        let f = try WorkTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = WorkTurnRunner(question: try f.question(["command": "rm -rf Archive"]))
        let service = try f.service(store, runner: runner)
        let progress = WorkTurnProgressLog()
        let turn = Task { await service.sendText(f.submission()) { await progress.append($0) } }
        let approval = try await progress.waitForApproval()
        #expect(approval.title == "Delete files with a command")
        #expect(await service.decideApproval(id: approval.id, allow: false))
        #expect(await turn.value.outcome == .completed)
        let answer = try #require(await runner.answers.first.map { String(decoding: $0, as: UTF8.self) })
        #expect(answer.contains("\"behavior\":\"deny\""))
        #expect(try await store.approval(id: ApprovalID(approval.id))?.state == .denied)
        // Nothing was done, so the record never says it was.
        let lines = try await store.runActivity(conversationID: f.conversationID, limit: 50).map(\.line)
        #expect(lines.contains("Denied: delete files with a command"))
        #expect(!lines.contains { $0.hasPrefix("Ran ") }, "\(lines)")
    }

    @Test("A card the child withdrew and asked again for the same call reads as done once approved")
    func reaskedCardApprovedReadsAsDone() async throws {
        let f = try WorkTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = WorkTurnRunner(question: try f.question(["command": "mv a.txt b.txt"]), withdrawsQuestion: true, reasksAfterWithdraw: true)
        let service = try f.service(store, runner: runner)
        let progress = WorkTurnProgressLog()
        let turn = Task { await service.sendText(f.submission()) { await progress.append($0) } }
        let first = try await progress.waitForApproval()
        for _ in 0..<800 where await progress.approvals.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        let second = try #require(await progress.approvals.last)
        #expect(second.id != first.id)
        #expect(await service.decideApproval(id: second.id, allow: true))
        #expect(await turn.value.outcome == .completed)
        let lines = try await store.runActivity(conversationID: f.conversationID, limit: 50).map(\.line)
        let approved = try #require(lines.firstIndex(of: "Approved: move or rename files with a command"), "\(lines)")
        let ran = try #require(lines.firstIndex(of: "Ran `mv a.txt b.txt`"), "\(lines)")
        #expect(lines.contains("Card closed unanswered: move or rename files with a command") && ran > approved, "\(lines)")
    }

    @Test("A call that ran and failed is recorded as failed, not as done")
    func failedCallIsRecordedAsFailed() async throws {
        let f = try WorkTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = WorkTurnRunner(question: try f.question(["command": "ls -la"]), preamble: [
            .toolUse(ClaudeTextToolUse(id: "toolu_a", toolName: "Bash", inputJSON: try f.question(["command": "cat missing.md"]))),
            .toolFinished(toolUseID: "toolu_a", failed: true)])
        let service = try f.service(store, runner: runner)
        let progress = WorkTurnProgressLog()
        #expect(await service.sendText(f.submission()) { await progress.append($0) }.outcome == .completed)
        let lines = try await store.runActivity(conversationID: f.conversationID, limit: 50).map(\.line)
        #expect(lines.contains("Failed to run `cat missing.md`"), "\(lines)")
        #expect(!lines.contains("Ran `cat missing.md`"), "\(lines)")
    }

    @Test("A failed call's own words are kept on its record line, quoted")
    func failedCallKeepsItsWordsOnTheRecord() async throws {
        let f = try WorkTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = WorkTurnRunner(question: try f.question(["command": "ls -la"]), preamble: [
            .toolUse(ClaudeTextToolUse(id: "toolu_a", toolName: "Bash", inputJSON: try f.question(["command": "cat missing.md"]))),
            .toolFailureReason(toolUseID: "toolu_a", reason: "cat: missing.md: No such file or directory"),
            .toolFinished(toolUseID: "toolu_a", failed: true),
            // Words for a call this turn never announced are not kept anywhere.
            .toolFailureReason(toolUseID: "toolu_ghost", reason: "not ours")])
        let service = try f.service(store, runner: runner)
        #expect(await service.sendText(f.submission()) { _ in }.outcome == .completed)
        let lines = try await store.runActivity(conversationID: f.conversationID, limit: 50).map(\.line)
        #expect(lines.contains(#"Failed to run `cat missing.md`: "cat: missing.md: No such file or directory""#), "\(lines)")
        #expect(!lines.contains { $0.contains("not ours") }, "\(lines)")
    }

    @Test("A listing passes without a card and is recorded as activity")
    func readOnlyPasses() async throws {
        let f = try WorkTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = WorkTurnRunner(question: try f.question(["command": "ls -la"]))
        let service = try f.service(store, runner: runner)
        let progress = WorkTurnProgressLog()
        let result = await service.sendText(f.submission()) { await progress.append($0) }
        #expect(result.outcome == .completed)
        #expect(await progress.approvals.isEmpty)
        let answer = try #require(await runner.answers.first.map { String(decoding: $0, as: UTF8.self) })
        #expect(answer.contains("\"behavior\":\"allow\""))
        #expect(await progress.activities.contains("Ran `ls -la` in Yogurt"))
        let lines = try await store.runActivity(conversationID: f.conversationID, limit: 50)
        #expect(lines.map(\.line) == ["Ran `ls -la` in Yogurt"])
        // A run keeps a bounded record, oldest lines first.
        let runID = try #require(lines.first?.runID)
        for index in 0..<(maximumRunActivityLines + 5) {
            try await store.recordRunActivity(runID: runID, line: "line \(index)", at: Date())
        }
        let capped = try await store.runActivity(conversationID: f.conversationID, limit: 1_000)
        #expect(capped.count == maximumRunActivityLines)
        #expect(capped.map(\.sequence) == Array(1...Int64(maximumRunActivityLines)))
    }

    @Test("A turn that ends takes its open card with it, recorded as expired")
    func cardClosedWithTheTurn() async throws {
        let f = try WorkTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = WorkTurnRunner(question: try f.question(["command": "mv a.txt b.txt"]), waitsForAnswer: false)
        let service = try f.service(store, runner: runner)
        let progress = WorkTurnProgressLog()
        let result = await service.sendText(f.submission()) { await progress.append($0) }
        #expect(result.outcome == .completed)
        let approval = try #require(await progress.approvals.first)
        #expect(await progress.resolved.contains(approval.id))
        #expect(try await store.approval(id: ApprovalID(approval.id))?.state == .expired)
        #expect(!(await service.decideApproval(id: approval.id, allow: true)))
    }

    @Test("The bot's question becomes a card; the answer goes back as the tool's own answers")
    func questionAnswered() async throws {
        let f = try WorkTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = WorkTurnRunner(question: try f.askedQuestions([f.colourQuestion]), toolName: "AskUserQuestion")
        let service = try f.service(store, runner: runner)
        let progress = WorkTurnProgressLog()
        let turn = Task { await service.sendText(f.submission()) { await progress.append($0) } }
        let question = try await progress.waitForQuestion()
        #expect(question.header == "Colour" && question.prompt == "Which colour do you prefer?")
        #expect(question.options.map(\.label) == ["Red", "Blue"] && !question.allowsMultiple && !question.isSecret)
        #expect(question.position == 1 && question.count == 1)
        #expect(await progress.approvals.isEmpty, "a question is not an approval card")
        #expect(await service.answerUserQuestion(id: question.id, answer: ClaudeTextQuestionAnswer(chosen: ["Blue"])))
        #expect(!(await service.answerUserQuestion(id: question.id, answer: ClaudeTextQuestionAnswer(chosen: ["Red"]))), "answered once")
        #expect(await turn.value.outcome == .completed)
        let answer = try #require(await runner.answers.first.map { String(decoding: $0, as: UTF8.self) })
        #expect(answer.contains("\"behavior\":\"allow\""))
        #expect(answer.contains("\"answers\":{\"Which colour do you prefer?\":\"Blue\"}"))
        #expect(answer.contains("\"questions\":["), "the tool's own input travels back with the answers")
        #expect(await progress.resolvedQuestions == [question.id])
        let lines = try await store.runActivity(conversationID: f.conversationID, limit: 50).map(\.line)
        #expect(lines.contains("Asked you: Which colour do you prefer?") && lines.contains("Answered: Blue"))
        #expect(!lines.contains("Asked you a question"), "one line per question: \(lines)")
    }

    @Test("Dismiss declines the question in one plain sentence; a secret is masked and never recorded; several questions come one at a time")
    func questionDismissedSecretAndSequence() async throws {
        let f = try WorkTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        // Dismiss.
        let dismissed = WorkTurnRunner(question: try f.askedQuestions([f.colourQuestion]), toolName: "AskUserQuestion")
        let service = try f.service(store, runner: dismissed)
        let log = WorkTurnProgressLog()
        let turn = Task { await service.sendText(f.submission()) { await log.append($0) } }
        let first = try await log.waitForQuestion()
        #expect(await service.answerUserQuestion(id: first.id, answer: nil))
        #expect(await turn.value.outcome == .completed)
        let denial = try #require(await dismissed.answers.first.map { String(decoding: $0, as: UTF8.self) })
        #expect(denial.contains("\"behavior\":\"deny\"") && denial.contains("dismissed the question"))
        // A secret, then a second question in the same call.
        let secretQuestion: [String: Any] = ["question": "What is the API key for the weather service?", "header": "API key",
                                             "options": [], "multiSelect": false]
        let sequence = WorkTurnRunner(question: try f.askedQuestions([secretQuestion, f.colourQuestion]), toolName: "AskUserQuestion")
        let service2 = try f.service(store, runner: sequence)
        let log2 = WorkTurnProgressLog()
        let turn2 = Task { await service2.sendText(f.submission()) { await log2.append($0) } }
        let secret = try await log2.waitForQuestion()
        #expect(secret.isSecret && secret.options.isEmpty && secret.position == 1 && secret.count == 2)
        #expect(await service2.answerUserQuestion(id: secret.id, answer: ClaudeTextQuestionAnswer(text: "sk-live-7777")))
        let second = try await log2.waitForQuestion(count: 2)
        #expect(second.prompt == "Which colour do you prefer?" && second.position == 2 && second.count == 2)
        #expect(await service2.answerUserQuestion(id: second.id, answer: ClaudeTextQuestionAnswer(chosen: ["Red"], text: "dark red")))
        #expect(await turn2.value.outcome == .completed)
        let answer = try #require(await sequence.answers.first.map { String(decoding: $0, as: UTF8.self) })
        // The model is told the secret's name, never its value.
        #expect(!answer.contains("sk-live-7777") && answer.contains("OPENBOTS_SECRET_1"), "\(answer)")
        #expect(answer.contains("\"Which colour do you prefer?\":\"Red, dark red\""))
        let lines = try await store.runActivity(conversationID: f.conversationID, limit: 100).map(\.line)
        #expect(lines.contains("Answered a question about a secret (kept private)"))
        #expect(!lines.joined(separator: "\n").contains("sk-live-7777"))
        #expect(lines.contains("Answered: Red, dark red"))
    }

    @Test("A secret given on a card never reaches the record or a later card, even when the bot echoes it")
    func secretIsScrubbedFromTheRecord() async throws {
        let f = try WorkTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let secretQuestion: [String: Any] = ["question": "What is the API token?", "header": "API token", "options": [], "multiSelect": false]
        let runner = WorkTurnRunner(question: try f.askedQuestions([secretQuestion]), toolName: "AskUserQuestion",
            followUp: ("Bash", try f.question(["command": "curl -H 'Authorization: Bearer sk-live-4242' https://example.com/api | tee out.json"])))
        let service = try f.service(store, runner: runner)
        let progress = WorkTurnProgressLog()
        let turn = Task { await service.sendText(f.submission()) { await progress.append($0) } }
        let question = try await progress.waitForQuestion()
        #expect(question.isSecret)
        #expect(await service.answerUserQuestion(id: question.id, answer: ClaudeTextQuestionAnswer(text: "sk-live-4242")))
        let card = try await progress.waitForApproval()
        #expect(!card.detail.contains("sk-live-4242") && card.detail.contains("•••"), "detail: \(card.detail)")
        #expect(await service.decideApproval(id: card.id, allow: false))
        #expect(await turn.value.outcome == .completed)
        let record = try await store.runActivity(conversationID: f.conversationID, limit: 100).map(\.line).joined(separator: "\n")
        #expect(!record.contains("sk-live-4242"))
        #expect(record.contains("Answered a question about a secret (kept private)"))
        #expect(record.contains("•••"), "the echoed command is on the record with the secret blanked")
        let activities = await progress.activities.joined(separator: "\n")
        #expect(!activities.contains("sk-live-4242"))
        // The model never had the value: only its name went back.
        let answer = try #require(await runner.answers.first.map { String(decoding: $0, as: UTF8.self) })
        #expect(!answer.contains("sk-live-4242") && answer.contains("OPENBOTS_SECRET_1"), "\(answer)")
    }

    // The value stays in the
    // app's memory for the turn; the model reads a name, and a command the user
    // approves gets the value set in front of it, in the allow answer only.
    @Test("A secret the user types reaches the model only as a name; a command naming it asks every time, shows only the name, and runs with the value set in front")
    func aSecretReachesTheModelOnlyAsAName() async throws {
        let f = try WorkTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let secretQuestion: [String: Any] = ["question": "What is the API token?", "header": "API token", "options": [], "multiSelect": false]
        let command = "curl -H \"Authorization: Bearer $OPENBOTS_SECRET_1\" https://example.com/api"
        let runner = WorkTurnRunner(question: try f.askedQuestions([secretQuestion]), toolName: "AskUserQuestion",
            followUps: [("Bash", try f.question(["command": command])), ("Bash", try f.question(["command": command]))])
        let service = try f.service(store, runner: runner)
        let progress = WorkTurnProgressLog()
        let turn = Task { await service.sendText(f.submission()) { await progress.append($0) } }
        let question = try await progress.waitForQuestion()
        #expect(await service.answerUserQuestion(id: question.id, answer: ClaudeTextQuestionAnswer(text: "it's-sk-4242")))
        let card = try await progress.waitForApproval()
        #expect(card.detail.contains("$OPENBOTS_SECRET_1") && !card.detail.contains("it's-sk-4242"), "\(card.detail)")
        #expect(card.target.contains("uses the secret you typed"), "\(card.target)")
        #expect(card.turnScopeFolder == nil, "a command carrying the user's secret never offers Allow for this turn")
        #expect(!(await service.allowApprovalForTurn(id: card.id)))
        #expect(await service.decideApproval(id: card.id, allow: true))
        // The second, identical command asks again: nothing covers it.
        let again = try await progress.waitForApproval(count: 2)
        #expect(await service.decideApproval(id: again.id, allow: false))
        #expect(await turn.value.outcome == .completed)
        let answers = await runner.answers.map { String(decoding: $0, as: UTF8.self) }
        #expect(answers.count == 3, "\(answers)")
        let told = try #require(answers.first)
        #expect(!told.contains("it's-sk-4242") && told.contains("\\\"$OPENBOTS_SECRET_1\\\""), "\(told)")
        let allowed = try #require(answers.dropFirst().first)
        // JSON writes the shell's quoting as is: 'it'\''s-sk-4242'.
        #expect(allowed.contains("export OPENBOTS_SECRET_1='it'\\\\''s-sk-4242'; curl -H"), "\(allowed)")
        #expect(allowed.contains("\"behavior\":\"allow\""))
        let record = try await store.runActivity(conversationID: f.conversationID, limit: 100).map(\.line).joined(separator: "\n")
        let rows = try await store.approvals(conversationID: f.conversationID, limit: 10)
        #expect(!record.contains("it's-sk-4242") && !"\(rows)".contains("it's-sk-4242"))
    }

    // Seen on 2.1.282: a command that
    // prints the value puts it in the CLI's session file as the tool's result.
    @Test("A turn that ran a command with the user's secret keeps no session: the CLI's files go; a denied one keeps it",
          arguments: [true, false])
    func aTurnThatUsedASecretKeepsNoSession(_ approve: Bool) async throws {
        let f = try WorkTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let secretQuestion: [String: Any] = ["question": "What is the API token?", "header": "API token", "options": [], "multiSelect": false]
        let runner = WorkTurnRunner(question: try f.askedQuestions([secretQuestion]), toolName: "AskUserQuestion",
            followUp: ("Bash", try f.question(["command": "printf '%s\\n' \"$OPENBOTS_SECRET_1\""])))
        let removed = RemovedTranscripts()
        let service = OfficialClaudeTextReplyService(repository: store, teammates: store, conversations: store,
            messages: store, preparer: WorkTurnPreparer(target: try f.target()), runner: runner,
            appOwnerID: f.appOwner, webAccess: WorkTurnAccess(access: try f.access()),
            approvals: store, activity: store, sessions: store, resumesSessions: true,
            sessionTranscriptExists: { _, _ in true },
            sessionTranscriptRemove: { _, id in
                removed.append(id)
                return ClaudeSessionTranscriptRemoval(removedPaths: [], droppedHistoryLines: 0)
            })
        let progress = WorkTurnProgressLog()
        let turn = Task { await service.sendText(f.submission()) { await progress.append($0) } }
        let question = try await progress.waitForQuestion()
        #expect(await service.answerUserQuestion(id: question.id, answer: ClaudeTextQuestionAnswer(text: "sk-live-4242")))
        let card = try await progress.waitForApproval()
        #expect(await service.decideApproval(id: card.id, allow: approve))
        #expect(await turn.value.outcome == .completed)
        let request = try #require(await runner.requests.first)
        #expect(request.persistsSession)
        let stored = try await store.storedClaudeSession(conversationID: f.conversationID, teammateID: f.teammateID)
        if approve {
            #expect(removed.ids == [request.sessionID] && stored == nil, "\(removed.ids) \(String(describing: stored))")
            let record = try await store.runActivity(conversationID: f.conversationID, limit: 100).map(\.line)
            #expect(record.contains(OfficialClaudeTextReplyService.secretSessionDroppedLine), "\(record)")
        } else {
            #expect(removed.ids.isEmpty && stored?.sessionID == request.sessionID)
        }
    }

    @Test("Each secret gets its own name; a command gets only the values it names; a longer number is not a shorter one")
    func secretAssignmentsNameOnlyWhatTheCommandUses() {
        let secrets = ["first-1111", "sec'ond-2222"]
        let assign = { OfficialClaudeTextReplyService.secretAssignments(command: $0, secrets: secrets) }
        #expect(assign("echo hi") == nil)
        #expect(assign("use \"$OPENBOTS_SECRET_1\"") == "export OPENBOTS_SECRET_1='first-1111'; ")
        #expect(assign("use ${OPENBOTS_SECRET_2}") == "export OPENBOTS_SECRET_2='sec'\\''ond-2222'; ")
        #expect(assign("a $OPENBOTS_SECRET_2 b $OPENBOTS_SECRET_1")
                == "export OPENBOTS_SECRET_1='first-1111'; export OPENBOTS_SECRET_2='sec'\\''ond-2222'; ")
        #expect(assign("use $OPENBOTS_SECRET_12") == nil)
        #expect(assign("use $OPENBOTS_SECRET_3") == nil)
    }

    @Test("A reply that repeats the user's secret is saved, shown and streamed with it blanked, and every checkpoint is a prefix of the next")
    func aReplyRepeatingASecretIsBlanked() async throws {
        let f = try WorkTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let secretQuestion: [String: Any] = ["question": "What is the API token?", "header": "API token", "options": [], "multiSelect": false]
        let runner = WorkTurnRunner(question: try f.askedQuestions([secretQuestion]), toolName: "AskUserQuestion",
            closingText: "Signed in with sk-live-4242, then sk-live-9 was wrong.")
        let service = try f.service(store, runner: runner)
        let progress = WorkTurnProgressLog()
        let turn = Task { await service.sendText(f.submission()) { await progress.append($0) } }
        let question = try await progress.waitForQuestion()
        #expect(await service.answerUserQuestion(id: question.id, answer: ClaudeTextQuestionAnswer(text: "sk-live-4242")))
        let result = await turn.value
        #expect(result.outcome == .completed)
        let saved = try #require(result.savedReplyMessage)
        let text = saved.parts.compactMap { part -> String? in if case .text(let t) = part.content { return t }; return nil }.joined()
        #expect(text == "Signed in with •••, then sk-live-9 was wrong.", "\(text)")
        let bubbles = await progress.bubbles.joined(separator: "\n")
        #expect(!bubbles.contains("sk-live-4242") && !bubbles.contains("sk-live-42"), "\(bubbles)")
    }

    @Test("Text saved before the user typed a secret is never cut back, even when it ends the way the secret begins")
    func textSavedBeforeTheSecretIsNeverCutBack() async throws {
        let f = try WorkTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let secretQuestion: [String: Any] = ["question": "What is the API token?", "header": "API token", "options": [], "multiSelect": false]
        let runner = WorkTurnRunner(question: try f.askedQuestions([secretQuestion]), toolName: "AskUserQuestion",
            followUp: ("Bash", try f.question(["command": "mv a.txt b.txt"])),
            preamble: [.textSnapshot("I need one of your keys")], repeatsTextAfterAnswer: true)
        let service = try f.service(store, runner: runner)
        let progress = WorkTurnProgressLog()
        let turn = Task { await service.sendText(f.submission()) { await progress.append($0) } }
        let question = try await progress.waitForQuestion()
        #expect(await service.answerUserQuestion(id: question.id, answer: ClaudeTextQuestionAnswer(text: "sk-live-4242")))
        // The call after it writes the held text out before its card goes up.
        let card = try await progress.waitForApproval()
        #expect(await service.decideApproval(id: card.id, allow: true))
        let result = await turn.value
        #expect(result.outcome == .completed, "\(result.outcome)")
    }

    // Text saved before the
    // secret was typed can hold it by chance; the reply must still only grow,
    // at every step, however often the secret comes back.
    @Test("A secret already in text written before the user typed it leaves that text alone, blanks what follows, and every step grows")
    func aSecretInEarlierTextStillGrows() {
        typealias Service = OfficialClaudeTextReplyService
        func check(_ full: String, _ secret: String, from: Int, expect: String) {
            let secrets = [Service.GivenSecret(value: secret, from: from)]
            var previous = String(full.prefix(from))
            for end in (from...full.count) {
                let shown = Service.blankReply(String(full.prefix(end)), secrets: secrets, streaming: true)
                #expect(shown.hasPrefix(previous), "\(previous) -> \(shown)")
                previous = shown
            }
            let final = Service.blankReply(full, secrets: secrets, streaming: false)
            #expect(final.hasPrefix(previous) && final == expect, "\(final)")
        }
        check("In 2024 we met, 2024. Bye 2024 again.", "2024", from: 10, expect: "In 2024 we met, •••. Bye ••• again.")
        check("code sk-live-4242 ok, sk-live-4242.", "sk-live-4242", from: 10, expect: "code sk-li••• ok, •••.")
        check("Plain text, nothing here.", "sk-live-4242", from: 3, expect: "Plain text, nothing here.")
    }

    @Test("A secret the user typed mid-reply that the bot then repeats twice still saves the reply whole")
    func aRepeatedSecretAfterEarlierTextSaves() async throws {
        let f = try WorkTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let secretQuestion: [String: Any] = ["question": "What is your secret PIN?", "header": "Secret PIN", "options": [], "multiSelect": false]
        // Text after the answer, then a card: the held text holding the first
        // blank is written out, and the reply goes on growing past it.
        let runner = WorkTurnRunner(question: try f.askedQuestions([secretQuestion]), toolName: "AskUserQuestion",
            followUp: ("Bash", try f.question(["command": "mv a.txt b.txt"])),
            preamble: [.textSnapshot("In 2024 we")], closingText: "met, 2024. Bye 2024.",
            textAfterAnswer: "In 2024 we\n\nmet, 2024.")
        let service = try f.service(store, runner: runner)
        let progress = WorkTurnProgressLog()
        let turn = Task { await service.sendText(f.submission()) { await progress.append($0) } }
        let question = try await progress.waitForQuestion()
        #expect(await service.answerUserQuestion(id: question.id, answer: ClaudeTextQuestionAnswer(text: "2024")))
        let card = try await progress.waitForApproval()
        #expect(await service.decideApproval(id: card.id, allow: true))
        let result = await turn.value
        #expect(result.outcome == .completed, "\(result.outcome)")
        let saved = try #require(result.savedReplyMessage)
        let text = saved.parts.compactMap { part -> String? in if case .text(let t) = part.content { return t }; return nil }.joined()
        #expect(text == "In 2024 we\n\nmet, •••. Bye •••.", "\(text)")
    }

    @Test("Blanking a reply as it streams never shows a secret's head and only ever grows")
    func streamingBlankOnlyGrows() {
        let secrets = ["sk-live-4242"]
        let full = "Use sk-live-4242 now, not sk-live-9 or sk-live-4242."
        var previous = ""
        for end in full.indices.dropFirst() + [full.endIndex] {
            let shown = OfficialClaudeTextReplyService.scrubStreaming(String(full[..<end]), secrets: secrets)
            #expect(shown.hasPrefix(previous), "\(previous) -> \(shown)")
            #expect(!shown.contains("sk-live-4"), "\(shown)")
            previous = shown
        }
        #expect(OfficialClaudeTextReplyService.scrubReply(full, secrets: secrets).hasPrefix(previous))
        #expect(OfficialClaudeTextReplyService.scrubReply(full, secrets: secrets) == "Use ••• now, not sk-live-9 or •••.")
        #expect(OfficialClaudeTextReplyService.scrubStreaming(full, secrets: []) == full)
    }

    @Test("A secret cut in two by a card's length limit leaves no head behind on the card, the record or the screen")
    func aSecretCutByALimitLeavesNoHead() async throws {
        let f = try WorkTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let secretQuestion: [String: Any] = ["question": "What is the API token?", "header": "API token", "options": [], "multiSelect": false]
        // The activity line clips the command at 160 characters; the token starts a few characters before the cut.
        let padding = String(repeating: "x", count: 146)
        let command = "echo \(padding) sk-live-4242 | tee out.json"
        let runner = WorkTurnRunner(question: try f.askedQuestions([secretQuestion]), toolName: "AskUserQuestion",
            followUp: ("Bash", try f.question(["command": command])))
        let service = try f.service(store, runner: runner)
        let progress = WorkTurnProgressLog()
        let turn = Task { await service.sendText(f.submission()) { await progress.append($0) } }
        let question = try await progress.waitForQuestion()
        #expect(await service.answerUserQuestion(id: question.id, answer: ClaudeTextQuestionAnswer(text: "sk-live-4242")))
        let card = try await progress.waitForApproval()
        #expect(!card.detail.contains("sk-l") && !card.target.contains("sk-l"), "detail: \(card.detail)")
        #expect(await service.decideApproval(id: card.id, allow: false))
        _ = await turn.value
        let record = try await store.runActivity(conversationID: f.conversationID, limit: 100).map(\.line).joined(separator: "\n")
        #expect(!record.contains("sk-l"), "record: \(record)")
        #expect(!(await progress.activities.joined(separator: "\n")).contains("sk-l"))
    }

    @Test("The blanking removes a secret whole, and a head of four or more characters left at a cut, and nothing shorter")
    func scrubBlanksHeadsLeftAtACut() {
        let secrets = ["sk-live-4242"]
        let scrub = { OfficialClaudeTextReplyService.scrub($0, secrets: secrets) }
        #expect(scrub("token sk-live-4242 here") == "token ••• here")
        #expect(scrub("Ran `echo abc sk-live-4…") == "Ran `echo abc •••…")
        #expect(scrub("Replace:\nold sk-li…\n\nWith:\nnew") == "Replace:\nold •••…\n\nWith:\nnew")
        #expect(scrub("a detail cut without a mark sk-live") == "a detail cut without a mark •••")
        #expect(scrub("ends with sk-") == "ends with sk-")
        #expect(scrub("sk-live is mentioned, then more text") == "sk-live is mentioned, then more text")
    }

    /// Every other card shows a secret the user gave as `•••` and still asks. A text
    /// card cannot: it shows the exact words that leave the user's number, and a
    /// card reading `•••` over a text carrying the secret itself is a card that
    /// describes a different text from the one sent.
    @Test("A text carrying a secret the user gave on a card is refused rather than shown to the user blanked, and one without still asks")
    func aTextCarryingASecretIsRefused() async throws {
        let f = try WorkTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let secretQuestion: [String: Any] = ["question": "What is the API token?", "header": "API token",
                                             "options": [], "multiSelect": false]
        let tool = "mcp__\(WorkAndMessagesAccess.serverName)__send_message"
        func service(_ runner: WorkTurnRunner) throws -> OfficialClaudeTextReplyService {
            OfficialClaudeTextReplyService(repository: store, teammates: store, conversations: store,
                messages: store, preparer: WorkTurnPreparer(target: try f.target()), runner: runner,
                appOwnerID: f.appOwner, webAccess: WorkAndMessagesAccess(access: try f.access()),
                approvals: store, activity: store)
        }

        let leaking = WorkTurnRunner(question: try f.askedQuestions([secretQuestion]), toolName: "AskUserQuestion",
            followUp: (tool, try f.question(["recipient": "+33612345678", "service": "SMS",
                                             "text": "The token is sk-live-4242, use it tonight."])))
        let first = try service(leaking)
        let progress = WorkTurnProgressLog()
        let turn = Task { await first.sendText(f.submission()) { await progress.append($0) } }
        let question = try await progress.waitForQuestion()
        #expect(await first.answerUserQuestion(id: question.id, answer: ClaudeTextQuestionAnswer(text: "sk-live-4242")))
        #expect(await turn.value.outcome == .completed)
        #expect(await progress.approvals.isEmpty, "no card may show a text that differs from the one sent")
        let refusal = try #require(await leaking.answers.last.map { String(decoding: $0, as: UTF8.self) })
        #expect(refusal.contains("\"behavior\":\"deny\"") && refusal.contains("Nothing was sent"), "\(refusal)")
        let record = try await store.runActivity(conversationID: f.conversationID, limit: 100).map(\.line)
        #expect(record.contains("Blocked a text that carried a secret you gave"), "\(record)")
        #expect(!record.joined(separator: "\n").contains("sk-live-4242"))

        // The same send without the secret in it is an ordinary card.
        let clean = WorkTurnRunner(question: try f.askedQuestions([secretQuestion]), toolName: "AskUserQuestion",
            followUp: (tool, try f.question(["recipient": "+33612345678", "service": "SMS",
                                             "text": "Use the token I gave you tonight."])))
        let second = try service(clean)
        let cleanProgress = WorkTurnProgressLog()
        let cleanTurn = Task { await second.sendText(f.submission()) { await cleanProgress.append($0) } }
        let asked = try await cleanProgress.waitForQuestion()
        #expect(await second.answerUserQuestion(id: asked.id, answer: ClaudeTextQuestionAnswer(text: "sk-live-4242")))
        let card = try await cleanProgress.waitForApproval()
        #expect(card.title == "Send a text as you")
        #expect(card.detail.hasSuffix("Use the token I gave you tonight."))
        #expect(await second.decideApproval(id: card.id, allow: false))
        #expect(await cleanTurn.value.outcome == .completed)
    }

    /// A note card shows the exact words written into the user's Notes, on the text
    /// card's rule: a note carrying a secret the user gave is refused, and
    /// a clean one is shown whole, never blanked.
    @Test("A note carrying a secret the user gave on a card is refused, and one without asks with its exact text")
    func aNoteCarryingASecretIsRefused() async throws {
        let f = try WorkTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let secretQuestion: [String: Any] = ["question": "What is the API token?", "header": "API token",
                                             "options": [], "multiSelect": false]
        let tool = "mcp__\(WorkAndMessagesAccess.serverName)__add_note"
        func service(_ runner: WorkTurnRunner) throws -> OfficialClaudeTextReplyService {
            OfficialClaudeTextReplyService(repository: store, teammates: store, conversations: store,
                messages: store, preparer: WorkTurnPreparer(target: try f.target()), runner: runner,
                appOwnerID: f.appOwner, webAccess: WorkAndMessagesAccess(access: try f.access(), role: .appleNotes),
                approvals: store, activity: store)
        }

        let leaking = WorkTurnRunner(question: try f.askedQuestions([secretQuestion]), toolName: "AskUserQuestion",
            followUp: (tool, try f.question(["name": "Keys", "content": "The token is sk-live-4242."])))
        let first = try service(leaking)
        let progress = WorkTurnProgressLog()
        let turn = Task { await first.sendText(f.submission()) { await progress.append($0) } }
        let question = try await progress.waitForQuestion()
        #expect(await first.answerUserQuestion(id: question.id, answer: ClaudeTextQuestionAnswer(text: "sk-live-4242")))
        #expect(await turn.value.outcome == .completed)
        #expect(await progress.approvals.isEmpty, "no card may show a note that differs from the one written")
        let refusal = try #require(await leaking.answers.last.map { String(decoding: $0, as: UTF8.self) })
        #expect(refusal.contains("\"behavior\":\"deny\"") && refusal.contains("Nothing was written"), "\(refusal)")
        let record = try await store.runActivity(conversationID: f.conversationID, limit: 100).map(\.line)
        #expect(record.contains("Blocked a note that carried a secret you gave"), "\(record)")
        #expect(!record.joined(separator: "\n").contains("sk-live-4242"))

        let clean = WorkTurnRunner(question: try f.askedQuestions([secretQuestion]), toolName: "AskUserQuestion",
            followUp: (tool, try f.question(["name": "Keys", "content": "Use the token I gave you, sk-live."])))
        let second = try service(clean)
        let cleanProgress = WorkTurnProgressLog()
        let cleanTurn = Task { await second.sendText(f.submission()) { await cleanProgress.append($0) } }
        let asked = try await cleanProgress.waitForQuestion()
        #expect(await second.answerUserQuestion(id: asked.id, answer: ClaudeTextQuestionAnswer(text: "sk-live-4242")))
        let card = try await cleanProgress.waitForApproval()
        #expect(card.title == "Add a note")
        // "sk-live" is the secret's first seven characters: blanked on any
        // other card, shown whole on this one.
        #expect(card.detail.hasSuffix("Use the token I gave you, sk-live."))
        #expect(await second.decideApproval(id: card.id, allow: false))
        #expect(await cleanTurn.value.outcome == .completed)
    }

    /// The blanking also takes a secret's first four or more characters off
    /// the end of any string, for a card cut short by its length limit; nothing
    /// on a text card is cut. Asking "did the blanking change the card?" so
    /// refused a text that only ended the way a secret begins, and would have
    /// shown `•••` in place of its last word had it asked. The question is
    /// whether a secret the user gave is in what the text sends.
    @Test("A text that only brushes a secret the user gave still asks and shows its words whole; one sending the secret to a number is refused")
    func aTextNearASecretStillAsks() async throws {
        let f = try WorkTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let secretQuestion: [String: Any] = ["question": "What is the API token?", "header": "API token",
                                             "options": [], "multiSelect": false]
        let tool = "mcp__\(WorkAndMessagesAccess.serverName)__send_message"
        func turn(secret: String, input: [String: Any]) async throws
            -> (runner: WorkTurnRunner, service: OfficialClaudeTextReplyService, progress: WorkTurnProgressLog,
                turn: Task<ClaudeTextTurnResult, Never>) {
            let runner = WorkTurnRunner(question: try f.askedQuestions([secretQuestion]), toolName: "AskUserQuestion",
                                        followUp: (tool, try f.question(input)))
            let service = OfficialClaudeTextReplyService(repository: store, teammates: store, conversations: store,
                messages: store, preparer: WorkTurnPreparer(target: try f.target()), runner: runner,
                appOwnerID: f.appOwner, webAccess: WorkAndMessagesAccess(access: try f.access()),
                approvals: store, activity: store)
            let progress = WorkTurnProgressLog()
            let task = Task { await service.sendText(f.submission()) { await progress.append($0) } }
            let question = try await progress.waitForQuestion()
            #expect(await service.answerUserQuestion(id: question.id, answer: ClaudeTextQuestionAnswer(text: secret)))
            return (runner, service, progress, task)
        }

        for text in ["Count me in for the hunt", "Happy hunt\u{2026} see you there"] {
            let open = try await turn(secret: "hunter22", input: ["recipient": "+33612345678", "service": "SMS",
                                                                 "text": text])
            let card = try await open.progress.waitForApproval()
            #expect(card.title == "Send a text as you")
            #expect(card.detail.hasSuffix("\n\n" + text) && !card.detail.contains("\u{2022}"),
                    Comment(rawValue: card.detail))
            let row = try #require(try await store.approval(id: ApprovalID(card.id)))
            #expect(row.exactTargetSummary.hasSuffix(text), Comment(rawValue: row.exactTargetSummary))
            #expect(await open.service.decideApproval(id: card.id, allow: false))
            #expect(await open.turn.value.outcome == .completed)
        }

        // A secret the user gave is a number the text would go to: refused, as a
        // secret in the words is.
        let toTheSecret = try await turn(secret: "33612345678", input: ["recipient": "+33612345678", "service": "SMS",
                                                                        "text": "hello"])
        #expect(await toTheSecret.turn.value.outcome == .completed)
        #expect(await toTheSecret.progress.approvals.isEmpty)
        let refusal = try #require(await toTheSecret.runner.answers.last.map { String(decoding: $0, as: UTF8.self) })
        #expect(refusal.contains("\"behavior\":\"deny\"") && refusal.contains("Nothing was sent"), "\(refusal)")
    }

    /// The approvals record keeps a card's detail through `DomainText.required`,
    /// which trims whitespace from both ends. A text card's detail ends with
    /// the text, so a text ending in a space went on the record without it —
    /// a record of a different text from the one on the card. A worst-case
    /// test that built the record by hand from a text of x's could not see it.
    @Test("A text card is on the approvals record exactly as the user saw it, and a text ending in a space the record would drop is refused")
    func aTextCardIsRecordedExactly() async throws {
        let f = try WorkTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let tool = "mcp__\(WorkAndMessagesAccess.serverName)__send_message"
        func send(_ text: String) async throws -> (card: ClaudeTextApproval?, answers: [String]) {
            let runner = WorkTurnRunner(question: try f.question(["recipient": "+33612345678", "service": "SMS",
                                                                  "text": text]), toolName: tool)
            let service = OfficialClaudeTextReplyService(repository: store, teammates: store, conversations: store,
                messages: store, preparer: WorkTurnPreparer(target: try f.target()), runner: runner,
                appOwnerID: f.appOwner, webAccess: WorkAndMessagesAccess(access: try f.access()),
                approvals: store, activity: store)
            let progress = WorkTurnProgressLog()
            let turn = Task { await service.sendText(f.submission()) { await progress.append($0) } }
            for _ in 0..<800 {
                let carded = !(await progress.approvals.isEmpty)
                let answered = !(await runner.answers.isEmpty)
                if carded || answered { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let card = await progress.approvals.first
            if let card { #expect(await service.decideApproval(id: card.id, allow: false)) }
            #expect(await turn.value.outcome == .completed)
            return (card, await runner.answers.map { String(decoding: $0, as: UTF8.self) })
        }

        // Spaces inside, and at the end of an inner line, are on the record too.
        let inner = "Line one  \nLine two"
        let shown = try #require(try await send(inner).card)
        let row = try #require(try await store.approval(id: ApprovalID(shown.id)))
        #expect(row.exactTargetSummary == shown.detail && shown.detail.hasSuffix(inner),
                Comment(rawValue: row.exactTargetSummary.debugDescription))

        for text in ["See you at 8 ", "See you at 8\t", "See you at 8\u{A0}", "See you at 8\u{3000}"] {
            let outcome = try await send(text)
            if let card = outcome.card {
                let recorded = try #require(try await store.approval(id: ApprovalID(card.id)))
                #expect(recorded.exactTargetSummary == card.detail,
                        Comment(rawValue: "the card showed \(card.detail.debugDescription) and the record kept "
                            + recorded.exactTargetSummary.debugDescription))
            }
            #expect(outcome.card == nil && outcome.answers.contains { $0.contains("\"behavior\":\"deny\"") },
                    Comment(rawValue: "\(text.debugDescription) must be refused: \(outcome.answers)"))
        }
    }

    @Test("A call a rule refused is on the record as kept out, and the turn goes on to its card")
    func ruleRefusalIsRecorded() async throws {
        let f = try WorkTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = WorkTurnRunner(question: try f.question(["command": "ls -la"]),
            refusal: ("Read", try f.question(["file_path": "/Users/x/.ssh/config"])))
        let service = try f.service(store, runner: runner)
        let progress = WorkTurnProgressLog()
        let result = await service.sendText(f.submission()) { await progress.append($0) }
        #expect(result.outcome == .completed)
        let lines = try await store.runActivity(conversationID: f.conversationID, limit: 50).map(\.line)
        #expect(lines.contains { $0.hasPrefix("Kept out by rule: read ") && $0.contains(".ssh/config") }, "\(lines)")
        #expect(!lines.contains { $0.hasPrefix("Read ") && $0.contains(".ssh/config") }, "\(lines)")
        #expect(lines.contains("Ran `ls -la` in Yogurt"))
    }

    @Test("A later question that echoes the secret shows it blanked")
    func secretIsScrubbedFromALaterQuestion() async throws {
        let f = try WorkTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let secretQuestion: [String: Any] = ["question": "What is the API token?", "header": "API token", "options": [], "multiSelect": false]
        let echo: [String: Any] = ["question": "Is sk-live-4242 the right token?", "header": "Check",
                                   "options": [["label": "Yes, sk-live-4242", "description": "Use sk-live-4242."], ["label": "No", "description": ""]], "multiSelect": false]
        let runner = WorkTurnRunner(question: try f.askedQuestions([secretQuestion]), toolName: "AskUserQuestion",
            followUp: ("AskUserQuestion", try f.askedQuestions([echo])))
        let service = try f.service(store, runner: runner)
        let progress = WorkTurnProgressLog()
        let turn = Task { await service.sendText(f.submission()) { await progress.append($0) } }
        let first = try await progress.waitForQuestion()
        #expect(await service.answerUserQuestion(id: first.id, answer: ClaudeTextQuestionAnswer(text: "sk-live-4242")))
        let second = try await progress.waitForQuestion(count: 2)
        #expect(second.prompt == "Is ••• the right token?" && second.options.map(\.label) == ["Yes, •••", "No"])
        #expect(second.options.first?.detail == "Use •••.")
        // Picking the blanked label sends the label as the bot wrote it.
        #expect(await service.answerUserQuestion(id: second.id, answer: ClaudeTextQuestionAnswer(chosen: ["Yes, •••"])))
        #expect(await turn.value.outcome == .completed)
        let answer = try #require(await runner.answers.last.map { String(decoding: $0, as: UTF8.self) })
        #expect(answer.contains("\"Is sk-live-4242 the right token?\":\"Yes, sk-live-4242\""))
        let record = try await store.runActivity(conversationID: f.conversationID, limit: 100).map(\.line).joined(separator: "\n")
        #expect(!record.contains("sk-live-4242") && record.contains("Answered: Yes, •••"), "record: \(record)")
        // A secret that is a prefix of another never leaves its tail behind.
        #expect(OfficialClaudeTextReplyService.scrub("sk-live-4242 and sk-live", secrets: ["sk-live", "sk-live-4242"]) == "••• and •••")
    }

    @Test("A beat goes on the record once per round of tool calls")
    func beatOnceARound() async throws {
        let f = try WorkTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let read = try f.question(["file_path": "/Users/x/OpenBots Next Preview Content/Bots/Yogurt/notes.md"])
        let runner = WorkTurnRunner(question: try f.question(["command": "ls -la"]),
            preamble: [.textSnapshot("Checking the folder."),
                       .toolUse(ClaudeTextToolUse(id: "toolu_a", toolName: "Read", inputJSON: read)),
                       .toolUse(ClaudeTextToolUse(id: "toolu_b", toolName: "Read", inputJSON: read))])
        let service = try f.service(store, runner: runner)
        let progress = WorkTurnProgressLog()
        let outcome = await service.sendText(f.submission()) { await progress.append($0) }.outcome
        #expect(outcome == .completed, "\(outcome)")
        let lines = try await store.runActivity(conversationID: f.conversationID, limit: 50).map(\.line)
        #expect(lines.filter { $0 == "Checking the folder." }.count == 1, "\(lines)")
        #expect(lines.filter { $0.hasPrefix("Read ") }.count == 2)
    }

    @Test("A card the child withdrew before the answer closes unanswered and cannot be answered after")
    func withdrawnCardClosesUnanswered() async throws {
        let f = try WorkTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = WorkTurnRunner(question: try f.question(["command": "mv a.txt b.txt"]), withdrawsQuestion: true)
        let service = try f.service(store, runner: runner)
        let progress = WorkTurnProgressLog()
        let turn = Task { await service.sendText(f.submission()) { await progress.append($0) } }
        let approval = try await progress.waitForApproval()
        let outcome = await turn.value.outcome
        #expect(outcome == .completed, "\(outcome)")
        #expect(!(await service.decideApproval(id: approval.id, allow: true)), "a withdrawn card cannot be answered")
        let lines = try await store.runActivity(conversationID: f.conversationID, limit: 50).map(\.line)
        #expect(lines.contains("Card closed unanswered: move or rename files with a command"), "\(lines)")
        #expect(!lines.contains { $0.hasPrefix("Ran ") }, "\(lines)")
        #expect(try await store.approval(id: ApprovalID(approval.id))?.state == .expired)
    }

    // Claude Code 2.1.282 requires two to four choices on every question the app's
    // CLI announces (the kind "text" schema is behind a flag it never gets), so a
    // question asking for a secret always comes with filler choices; without
    // this rule the card was a plain one and the typed token reached the model.
    @Test("A question whose words ask for a secret is a secret card, choices or none; a number question never is")
    func secretCardKinds() throws {
        let f = try WorkTurnFixture(); defer { f.remove() }
        let typed: [String: Any] = ["question": "What is the API token?", "header": "Token", "options": [], "kind": "text"]
        let number: [String: Any] = ["question": "How many token digits?", "header": "Token", "options": [], "kind": "number"]
        let choice: [String: Any] = ["question": "Which token do we use?", "header": "Token",
                                     "options": [["label": "A", "description": ""], ["label": "B", "description": ""]], "multiSelect": false]
        let plain: [String: Any] = ["question": "What is your name?", "header": "Name", "options": []]
        let parsed = try #require(OfficialClaudeTextReplyService.askedQuestions(try f.askedQuestions([typed, number, choice, plain])))
        #expect(parsed.map(\.isSecret) == [true, false, true, false])
        #expect(parsed.map(\.kind) == ["text", "number", "", ""])
    }

    // With choices allowed on a secret
    // card, the words alone decide, so an ordinary question about tokens (the
    // model's context) must not mask what the user types.
    @Test("The secret words match whole words only, and the plural \"tokens\" is not a secret")
    func secretWordsAreWholeWords() {
        let secret = ["What is the API token?", "Please provide the secret token for this test.", "Enter your password",
                      "Paste your api key here", "Which credential should I use?", "Your GitHub token, please"]
        let plain = ["More context tokens, or the faster model?", "How many tokens should the summary use?",
                     "Is this a secretary's address?", "Tokenize the file by words or lines?"]
        for prompt in secret { #expect(ClaudeTextQuestion.asksForASecret(header: "Question", prompt: prompt), "\(prompt)") }
        for prompt in plain { #expect(!ClaudeTextQuestion.asksForASecret(header: "Question", prompt: prompt), "\(prompt)") }
    }

    @Test("A secret question in 2.1.282's shape: typed text is the secret, a choice alone stays a plain answer",
          arguments: [true, false])
    func secretQuestionWithTheCLIsFillerChoices(_ types: Bool) async throws {
        let f = try WorkTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        // The call the model made on Claude Code 2.1.282.
        let asked: [String: Any] = ["question": "Please provide the secret token for this test (use \"Other\" to type it freely).",
            "header": "Token", "multiSelect": false,
            "options": [["label": "I'll type it via Other", "description": "Type the token in the Other field."],
                        ["label": "Skip this test", "description": "Do not test the secret card."]]]
        let runner = WorkTurnRunner(question: try f.askedQuestions([asked]), toolName: "AskUserQuestion")
        let service = try f.service(store, runner: runner)
        let progress = WorkTurnProgressLog()
        let turn = Task { await service.sendText(f.submission()) { await progress.append($0) } }
        let question = try await progress.waitForQuestion()
        #expect(question.isSecret && question.options.count == 2)
        let answer = types ? ClaudeTextQuestionAnswer(text: "CANARYplum7Q4Zx93")
            : ClaudeTextQuestionAnswer(chosen: ["Skip this test"])
        #expect(await service.answerUserQuestion(id: question.id, answer: answer))
        #expect(await turn.value.outcome == .completed)
        let toTool = await runner.answers.map { String(decoding: $0, as: UTF8.self) }.joined()
        let record = try await store.runActivity(conversationID: f.conversationID, limit: 50).map(\.line).joined(separator: "\n")
        #expect(!toTool.contains("CANARYplum7Q4Zx93") && !record.contains("CANARYplum7Q4Zx93"), "\(toTool)\n\(record)")
        if types {
            #expect(toTool.contains("OPENBOTS_SECRET_1"), "\(toTool)")
            #expect(record.contains("Answered a question about a secret (kept private)"), "\(record)")
        } else {
            #expect(toTool.contains("Skip this test") && !toTool.contains("OPENBOTS_SECRET_"), "\(toTool)")
            #expect(record.contains("Answered: Skip this test"), "\(record)")
        }
    }

    @Test("Without a work grant the turn is the shipped command and asks nothing")
    func noGrantIsUnchanged() async throws {
        let f = try WorkTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = WorkTurnRunner(question: try f.question(["command": "ls"]))
        let service = try f.service(store, runner: runner, granted: false)
        let progress = WorkTurnProgressLog()
        let result = await service.sendText(f.submission()) { await progress.append($0) }
        #expect(result.outcome == .completed)
        let request = try #require(await runner.requests.first)
        #expect(!request.grantsWork && request.expectedPermissionMode == "dontAsk")
        #expect(await runner.sawControl == false)
    }

    @Test("An edit in the bot's own folder goes through with no card and is still written to the record")
    func ownFolderEditIsQuietAndRecorded() async throws {
        let f = try WorkTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = WorkTurnRunner(question: try f.question([
            "file_path": f.ownFolder.appendingPathComponent("notes.md").path,
            "old_string": "a", "new_string": "b"]), toolName: "Edit")
        let service = try f.service(store, runner: runner)
        let progress = WorkTurnProgressLog()
        let result = await service.sendText(f.submission()) { await progress.append($0) }
        #expect(result.outcome == .completed)
        #expect(await progress.approvals.isEmpty, "the bot's own folder raises no card")
        let answers = await runner.answers
        #expect(answers.count == 1)
        #expect(answers.first.map { String(decoding: $0, as: UTF8.self) }?.contains("\"behavior\":\"allow\"") == true)
        // The record is complete: the row is there, approved, and says the rule
        // allowed it rather than the user.
        let cards = try await store.approvals(conversationID: f.conversationID, limit: 10)
        #expect(cards.count == 1 && cards.first?.state == .approved)
        #expect(cards.first?.consequenceSummary.contains(OfficialClaudeTextReplyService.ownFolderRule) == true,
                "\(cards.first?.consequenceSummary ?? "(no row)")")
        let lines = try await store.runActivity(conversationID: f.conversationID, limit: 50).map(\.line)
        #expect(lines.contains("Edited notes.md in Yogurt's folder"), "\(lines)")
        #expect(!lines.contains { $0.hasPrefix("Approved:") || $0.hasPrefix("Asked to change") }, "\(lines)")
    }

    @Test("A secret given on a card never reaches the approvals row of a quiet edit in the bot's own folder")
    func secretIsScrubbedFromTheQuietOwnFolderRow() async throws {
        let f = try WorkTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let secretQuestion: [String: Any] = ["question": "What is the API token?", "header": "API token", "options": [], "multiSelect": false]
        // The token in a file's name, then in the text an edit writes: both go
        // through without a card, and both rows are shown on the record screen.
        let runner = WorkTurnRunner(question: try f.askedQuestions([secretQuestion]), toolName: "AskUserQuestion",
            followUps: [("Write", try f.question(["file_path": f.ownFolder.appendingPathComponent("sk-live-4242.md").path,
                                                  "content": "token=sk-live-4242"])),
                        ("Edit", try f.question(["file_path": f.ownFolder.appendingPathComponent("notes.md").path,
                                                 "old_string": "token=", "new_string": "token=sk-live-4242"]))])
        let service = try f.service(store, runner: runner)
        let progress = WorkTurnProgressLog()
        let turn = Task { await service.sendText(f.submission()) { await progress.append($0) } }
        let question = try await progress.waitForQuestion()
        #expect(question.isSecret)
        #expect(await service.answerUserQuestion(id: question.id, answer: ClaudeTextQuestionAnswer(text: "sk-live-4242")))
        #expect(await turn.value.outcome == .completed)
        #expect(await progress.approvals.isEmpty, "the bot's own folder raises no card")
        let rows = try await store.approvals(conversationID: f.conversationID, limit: 10)
        #expect(rows.count == 2 && rows.allSatisfy { $0.state == .approved }, "\(rows.map(\.state))")
        // The file's name is masked; an edit's text is on the card only, never the row.
        #expect(rows.contains { $0.exactTargetSummary.contains("•••") }, "\(rows.map(\.exactTargetSummary))")
        for row in rows {
            #expect(row.consequenceSummary.contains(OfficialClaudeTextReplyService.ownFolderRule), "\(row.consequenceSummary)")
            #expect(!row.exactTargetSummary.contains("sk-live-4242"), "what the screen shows: \(row.exactTargetSummary)")
            #expect(!row.consequenceSummary.contains("sk-live-4242"), "\(row.consequenceSummary)")
        }
        let record = try await store.runActivity(conversationID: f.conversationID, limit: 100).map(\.line).joined(separator: "\n")
        #expect(!record.contains("sk-live-4242") && record.contains("Wrote •••.md in Yogurt's folder"), "\(record)")
        // The tool itself still got each call as the bot wrote it.
        let answers = await runner.answers.map { String(decoding: $0, as: UTF8.self) }
        #expect(answers.count == 3 && answers.dropFirst().allSatisfy { $0.contains("\"behavior\":\"allow\"") }, "\(answers)")
    }

    @Test("Allow for this turn covers the same tool in the same folder and nothing else")
    func allowForThisTurnCoversTheSameToolAndFolder() async throws {
        let f = try WorkTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        func edit(_ name: String, in folder: URL) throws -> Data {
            try f.question(["file_path": folder.appendingPathComponent(name).path,
                            "old_string": "a", "new_string": "b"])
        }
        let elsewhere = f.directory.appendingPathComponent("Elsewhere")
        let runner = WorkTurnRunner(question: try edit("2026.md", in: f.addedFolder), toolName: "Edit",
            followUps: [("Edit", try edit("2025.md", in: f.addedFolder)),
                        ("Edit", try edit("secret.md", in: elsewhere)),
                        ("Bash", try f.question(["command": "rm \(f.addedFolder.appendingPathComponent("2026.md").path)"]))])
        let service = try f.service(store, runner: runner, added: true)
        let progress = WorkTurnProgressLog()
        let turn = Task { await service.sendText(f.submission()) { await progress.append($0) } }
        let first = try await progress.waitForApproval()
        #expect(first.turnScopeFolder == "Invoices")
        #expect(await service.allowApprovalForTurn(id: first.id))
        // The second edit is the same tool in the same folder: no card. The third
        // is another folder and the fourth is a command: both ask again.
        let outside = try await progress.waitForApproval(count: 2)
        #expect(outside.detail.contains("Replace") && outside.target.contains("secret.md"))
        #expect(outside.turnScopeFolder == nil, "a card outside the granted folders names no folder to allow")
        #expect(await service.decideApproval(id: outside.id, allow: false))
        let command = try await progress.waitForApproval(count: 3)
        #expect(command.toolName == "Bash" && command.turnScopeFolder == nil, "a command is never remembered")
        #expect(await service.decideApproval(id: command.id, allow: false))
        let result = await turn.value
        #expect(result.outcome == .completed)
        #expect(await progress.approvals.count == 3, "only the second edit went through without a card")
        let cards = try await store.approvals(conversationID: f.conversationID, limit: 10)
        let states: [ApprovalState] = cards.map(\.state).sorted { $0.rawValue < $1.rawValue }
        #expect(states == [.approved, .approved, .denied, .denied])
        #expect(cards.filter { $0.consequenceSummary.contains(OfficialClaudeTextReplyService.earlierThisTurnRule) }.count == 1)
        let lines = try await store.runActivity(conversationID: f.conversationID, limit: 60).map(\.line)
        #expect(lines.contains("Allowed for the rest of this turn: change a file"), "\(lines)")
        #expect(lines.contains("Changed Invoices/2025.md · Allowed earlier this turn"), "\(lines)")
    }

    @Test("What was allowed for a turn is gone when the next turn asks the same thing")
    func allowForThisTurnDiesWithTheTurn() async throws {
        let f = try WorkTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = WorkTurnRunner(question: try f.question([
            "file_path": f.addedFolder.appendingPathComponent("2026.md").path,
            "old_string": "a", "new_string": "b"]), toolName: "Edit")
        let service = try f.service(store, runner: runner, added: true)
        let progress = WorkTurnProgressLog()
        let first = Task { await service.sendText(f.submission()) { await progress.append($0) } }
        let card = try await progress.waitForApproval()
        #expect(await service.allowApprovalForTurn(id: card.id))
        #expect(await first.value.outcome == .completed)
        // A new turn starts with nothing remembered.
        let second = Task { await service.sendText(f.submission()) { await progress.append($0) } }
        let again = try await progress.waitForApproval(count: 2)
        #expect(again.id != card.id && again.title == "Change a file")
        #expect(await service.decideApproval(id: again.id, allow: false))
        #expect(await second.value.outcome == .completed)
    }
}

@Suite("A question the turn never admitted is answered no, with a reason, and the turn goes on")
struct UnadmittedQuestionServiceTests {
    @Test("A sandbox network reach is denied by rule, recorded as activity, and the bot's answer still lands")
    func sandboxNetworkReachIsDeniedAndTheTurnCompletes() async throws {
        let f = try WorkTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = WorkTurnRunner(question: try f.question(["host": "school.example"]), toolName: "SandboxNetworkAccess", admitted: false)
        let service = try f.service(store, runner: runner)
        let progress = WorkTurnProgressLog()
        let outcome = await service.sendText(f.submission()) { await progress.append($0) }
        #expect(outcome.outcome == .completed)
        #expect(await progress.approvals.isEmpty)
        let answers = await runner.answers.map { String(decoding: $0, as: UTF8.self) }
        let answer = try #require(answers.first)
        #expect(answers.count == 1 && answer.contains("\"behavior\":\"deny\""))
        #expect(answer.contains("Use the web tools for school.example."))
        #expect(await progress.activities.contains("Blocked a shell connection to school.example"))
    }

    /// A field opening with U+FEFF is read one way here and another by the CLI
    /// and the server (`aHiddenMarkAtTheStartOfAStringIsFlagged`), so no card
    /// can show what would run: refused before any policy is asked.
    @Test("A question whose input the app cannot read as sent is denied, recorded, and the turn goes on")
    func aQuestionNotReadAsSentIsDenied() async throws {
        let f = try WorkTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = WorkTurnRunner(question: try f.question(["command": "ls"]), readsAsSent: false)
        let service = try f.service(store, runner: runner)
        let progress = WorkTurnProgressLog()
        let outcome = await service.sendText(f.submission()) { await progress.append($0) }
        #expect(outcome.outcome == .completed)
        #expect(await progress.approvals.isEmpty)
        let answers = await runner.answers.map { String(decoding: $0, as: UTF8.self) }
        let answer = try #require(answers.first)
        #expect(answers.count == 1 && answer.contains("\"behavior\":\"deny\""))
        #expect(answer.contains("invisible character"))
        #expect(await progress.activities.contains("Blocked a call whose details could not be read exactly"))
    }
}

private actor WorkTurnRunner: ClaudeTextOnlyRunning {
    private let question: Data
    private let toolName: String
    private let waitsForAnswer: Bool
    private(set) var requests: [ClaudeTextOnlyRequest] = []
    private(set) var answers: [Data] = []
    private(set) var sawControl = false
    private var textSoFar = ""

    /// A second request the child asks once the first answer arrived.
    /// The calls after the first, each announced and asked about in order.
    private let followUps: [(toolName: String, input: Data)]
    /// A call a rule refuses before anything is asked, announced then refused.
    private let refusal: (toolName: String, input: Data)?
    /// The child withdraws its question right after asking it.
    private let withdrawsQuestion: Bool
    /// After withdrawing, the child asks again for the same call and waits. A
    /// defensive shape: no capture shows 2.1.263 re-asking with the same
    /// tool_use_id, but the stream would admit it (only request ids are deduped).
    private let reasksAfterWithdraw: Bool
    /// Beats and tool calls announced before the question, in order.
    private let preamble: [ClaudeTextOnlyEvent]
    /// The reply's last words, streamed in growing snapshots, instead of "Done.".
    private let closingText: String?
    /// After the first answer the child sends its text so far again, unchanged.
    private let repeatsTextAfterAnswer: Bool
    /// After the first answer the child streams this text, before any further call.
    private let textAfterAnswer: String?
    /// The longest text sent so far: the CLI's snapshots only grow.
    private var sent = 0

    /// The CLI asked about a tool the turn never admitted (a sandbox network reach).
    private let admitted: Bool
    /// The question's input opened a string with U+FEFF, so the app's reading
    /// of it is not the CLI's.
    private let readsAsSent: Bool

    init(question: Data, toolName: String = "Bash", waitsForAnswer: Bool = true, followUp: (toolName: String, input: Data)? = nil,
         followUps: [(toolName: String, input: Data)] = [],
         refusal: (toolName: String, input: Data)? = nil, withdrawsQuestion: Bool = false, reasksAfterWithdraw: Bool = false,
         preamble: [ClaudeTextOnlyEvent] = [], admitted: Bool = true, readsAsSent: Bool = true,
         closingText: String? = nil, repeatsTextAfterAnswer: Bool = false, textAfterAnswer: String? = nil) {
        self.question = question; self.toolName = toolName; self.waitsForAnswer = waitsForAnswer; self.admitted = admitted
        self.readsAsSent = readsAsSent
        self.followUps = (followUp.map { [$0] } ?? []) + followUps
        self.refusal = refusal; self.withdrawsQuestion = withdrawsQuestion; self.reasksAfterWithdraw = reasksAfterWithdraw
        self.preamble = preamble
        self.closingText = closingText
        self.repeatsTextAfterAnswer = repeatsTextAfterAnswer
        self.textAfterAnswer = textAfterAnswer
    }

    func run(request: ClaudeTextOnlyRequest,
             onEvent: @escaping @Sendable (ClaudeTextOnlyEvent) async -> Void) async -> ClaudeTextOnlyResult {
        await run(request: request, control: nil, onEvent: onEvent)
    }

    /// Waits for the app's answer to the open request; true when it allowed the call.
    private func waitForAnswer(_ control: ClaudeTextTurnControl) async -> Bool {
        for _ in 0..<800 {
            let pending = control.takePending()
            if !pending.isEmpty {
                answers += pending
                return pending.contains { String(decoding: $0, as: UTF8.self).contains("\"behavior\":\"allow\"") }
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func run(request: ClaudeTextOnlyRequest, control: ClaudeTextTurnControl?,
             onEvent: @escaping @Sendable (ClaudeTextOnlyEvent) async -> Void) async -> ClaudeTextOnlyResult {
        requests.append(request)
        await onEvent(.initialized(sessionID: request.sessionID, actualModel: request.expectedResolvedModel))
        await onEvent(.inputSubmitted(messageID: request.messageID))
        await onEvent(.inputAcknowledged(messageID: request.messageID))
        if let control, request.grantsWork {
            sawControl = true
            if let refusal {
                await onEvent(.toolUse(ClaudeTextToolUse(id: "toolu_r", toolName: refusal.toolName, inputJSON: refusal.input)))
                await onEvent(.toolRefused(toolUseID: "toolu_r", toolName: refusal.toolName))
                await onEvent(.toolFinished(toolUseID: "toolu_r", failed: true))
            }
            for event in preamble {
                // A durable reply only grows, so a later snapshot extends an earlier one.
                if case .textSnapshot(let text) = event { textSoFar = text }
                await onEvent(event)
                // A call the CLI runs without asking (a read inside the folder) reports its result at once,
                // unless the preamble spells the result itself.
                if case .toolUse(let use) = event,
                   !preamble.contains(.toolFinished(toolUseID: use.id, failed: true)),
                   !preamble.contains(.toolFinished(toolUseID: use.id, failed: false)) {
                    await onEvent(.toolFinished(toolUseID: use.id, failed: false))
                }
            }
            // The CLI announces the call, then asks whether it may go ahead.
            await onEvent(.toolUse(ClaudeTextToolUse(id: "toolu_1", toolName: toolName, inputJSON: question)))
            let asked = ClaudeTextPermissionRequest(requestID: "req-1", toolUseID: "toolu_1", toolName: toolName, inputJSON: question, admitted: admitted,
                                                    inputReadsAsSent: readsAsSent)
            control.register(asked)
            await onEvent(.permissionRequested(asked))
            if withdrawsQuestion {
                control.withdraw(requestID: "req-1")
                await onEvent(.permissionCancelled(requestID: "req-1"))
                if reasksAfterWithdraw {
                    let again = ClaudeTextPermissionRequest(requestID: "req-1b", toolUseID: "toolu_1", toolName: toolName, inputJSON: question)
                    control.register(again)
                    await onEvent(.permissionRequested(again))
                    await onEvent(.toolFinished(toolUseID: "toolu_1", failed: await waitForAnswer(control) == false))
                } else {
                    await onEvent(.toolFinished(toolUseID: "toolu_1", failed: true))
                }
            }
            if waitsForAnswer, !withdrawsQuestion {
                await onEvent(.toolFinished(toolUseID: "toolu_1", failed: await waitForAnswer(control) == false))
                if repeatsTextAfterAnswer { await onEvent(.textSnapshot(textSoFar)) }
                if let textAfterAnswer {
                    // A reply only grows (the CLI's snapshots extend each other), so
                    // the text after the answer streams on from what was already sent.
                    // Restarting it from its first letter made the reply shrink, and
                    // under parallel test load a checkpoint landing there was
                    // refused and the turn stalled.
                    precondition(textAfterAnswer.hasPrefix(textSoFar))
                    for end in (textSoFar.count + 1)...textAfterAnswer.count {
                        await onEvent(.textSnapshot(String(textAfterAnswer.prefix(end))))
                    }
                    sent = textAfterAnswer.count
                }
                for (offset, followUp) in followUps.enumerated() {
                    let toolUseID = "toolu_\(offset + 2)", requestID = "req-\(offset + 2)"
                    await onEvent(.toolUse(ClaudeTextToolUse(id: toolUseID, toolName: followUp.toolName, inputJSON: followUp.input)))
                    let next = ClaudeTextPermissionRequest(requestID: requestID, toolUseID: toolUseID,
                        toolName: followUp.toolName, inputJSON: followUp.input)
                    control.register(next)
                    await onEvent(.permissionRequested(next))
                    await onEvent(.toolFinished(toolUseID: toolUseID, failed: await waitForAnswer(control) == false))
                }
            }
        }
        let closing = closingText ?? "Done."
        let finalText = textSoFar.isEmpty ? closing : textSoFar + "\n\n" + closing
        if closingText != nil {
            // Streamed a few characters at a time, as the CLI's partial messages arrive.
            var shown = textSoFar.isEmpty ? "" : textSoFar + "\n\n"
            for character in closing {
                shown.append(character)
                if shown.count > sent { await onEvent(.textSnapshot(shown)) }
            }
        }
        await onEvent(.textSnapshot(finalText))
        return .success(ClaudeTextOnlyReply(sessionID: request.sessionID, actualModel: request.expectedResolvedModel,
            text: finalText, confirmedActualModel: request.expectedResolvedModel))
    }
}

private struct WorkTurnTimeout: Error {}

private actor WorkTurnProgressLog {
    private(set) var approvals: [ClaudeTextApproval] = []
    private(set) var resolved: [UUID] = []
    private(set) var activities: [String] = []
    private(set) var questions: [ClaudeTextQuestion] = []
    private(set) var resolvedQuestions: [UUID] = []
    /// Every bubble list and saved reply text the screen was given.
    private(set) var bubbles: [String] = []

    func append(_ progress: ClaudeTextTurnProgress) {
        switch progress {
        case .bubbles(let committed): bubbles += committed.map { "\($0)" }
        case .assistantMessageSaved(let message): bubbles.append("\(message.parts)")
        case .approvalRequired(let approval): approvals.append(approval)
        case .approvalResolved(let id): resolved.append(id)
        case .activity(let line): activities.append(line)
        case .questionAsked(let question): questions.append(question)
        case .questionResolved(let id): resolvedQuestions.append(id)
        default: break
        }
    }

    func waitForQuestion(count: Int = 1) async throws -> ClaudeTextQuestion {
        for _ in 0..<800 {
            if questions.count >= count { return questions[count - 1] }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw WorkTurnTimeout()
    }

    func waitForApproval(count: Int = 1) async throws -> ClaudeTextApproval {
        for _ in 0..<800 {
            if approvals.count >= count { return approvals[count - 1] }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw WorkTurnTestError.noCard
    }
}

private enum WorkTurnTestError: Error { case noCard }

private struct WorkTurnAccess: ClaudeTextReplyWebAccessResolving {
    let access: ClaudeTextWorkAccess?
    func allowedTextReplyTools(teammateID: TeammateID) async -> Set<ClaudeTextOnlyTool> { [] }
    func webAccessChanges() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    func workAccess(teammateID: TeammateID) async -> ClaudeTextWorkAccess? { access }
}

/// A bot with its own folder and the Messages connector at once, so a secret
/// asked on a question card and a text can happen in the same turn.
private struct WorkAndMessagesAccess: ClaudeTextReplyWebAccessResolving {
    static let serverName = "openbots_" + String(repeating: "e", count: 64)
    let access: ClaudeTextWorkAccess
    /// Messages, or Apple Notes: the two connectors whose cards show exact words.
    var role: ClaudeTextConnectorRole = .appleMessages
    func allowedTextReplyTools(teammateID: TeammateID) async -> Set<ClaudeTextOnlyTool> { [] }
    func webAccessChanges() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    func workAccess(teammateID: TeammateID) async -> ClaudeTextWorkAccess? { access }
    func connectorAccess(teammateID: TeammateID, runID: UUID) async -> ClaudeTextConnectorAccess? {
        try? ClaudeTextConnectorAccess(servers: [
            ClaudeTextConnectorServer(name: Self.serverName, role: role,
                program: .installedTool(URL(fileURLWithPath: "/private/tmp/openbots-messages-fixture")),
                options: [], environment: [:]),
        ])
    }
    func grantedConnectorNames(teammateID: TeammateID) async -> Set<String> { [Self.serverName] }
}

private struct WorkTurnPreparer: ClaudeTextLaunchPreparing {
    let target: ClaudeConnectionTarget
    func prepareTextLaunch(runID: UUID) async -> ClaudeTextLaunchPreparation { .ready(target) }
}

private struct WorkTurnFixture: Sendable {
    let directory: URL
    let protection: ProtectionDecisionReceipt
    let teammateID = TeammateID(UUID()), conversationID = ConversationID(UUID())
    let appOwner = UUID()
    let date = Date(timeIntervalSince1970: 4_000)

    init() throws {
        directory = URL(fileURLWithPath: "/private/tmp/OpenBotsNextWorkTurn-\(UUID()).noindex", isDirectory: true)
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

    func seed(_ store: SQLiteStore) async throws {
        let teammate = try Teammate(id: teammateID,
            profile: TeammateProfile(displayName: "Yogurt", role: "Teammate", detailedInstructions: nil),
            appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 6,
                silhouette: "round", paletteToken: "sky", eyeDialect: "bright",
                nonColorIdentityCue: "single crest", accessibleIdentityDescription: "Round creature with a crest"),
            createdAt: date, updatedAt: date)
        try await store.provisionDirectChat(teammate: teammate,
            conversation: Conversation(id: conversationID, kind: .direct(teammateID: teammateID), createdAt: date, updatedAt: date),
            fixtureGreeting: nil, selectConversation: false)
    }

    var ownFolder: URL { directory.appendingPathComponent("Bots/Yogurt") }
    var addedFolder: URL { directory.appendingPathComponent("Invoices") }

    func access(added: Bool = false) throws -> ClaudeTextWorkAccess {
        try ClaudeTextWorkAccess(workingDirectoryURL: ownFolder,
            additionalDirectoryURLs: added ? [addedFolder] : [],
            protectedPaths: [directory.appendingPathComponent("home/.ssh").path])
    }

    func question(_ input: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
    }

    /// The question tool's input, as the CLI sends it over the channel.
    var colourQuestion: [String: Any] {
        ["question": "Which colour do you prefer?", "header": "Colour",
         "options": [["label": "Red", "description": "You prefer red."], ["label": "Blue", "description": "You prefer blue."]],
         "multiSelect": false]
    }

    func askedQuestions(_ questions: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["questions": questions], options: [.sortedKeys])
    }

    func submission() -> ClaudeTextTurnSubmission {
        ClaudeTextTurnSubmission(conversationID: conversationID, teammateID: teammateID,
            userMessageID: MessageID(UUID()), text: "Move a.txt into the archive.")
    }

    func target() throws -> ClaudeConnectionTarget {
        try ClaudeConnectionTarget(executableURL: URL(fileURLWithPath: "/fixture/claude"),
            expectedExecutableSHA256: String(repeating: "a", count: 64),
            profileURL: URL(fileURLWithPath: "/fixture/WorkTurn.noindex/CLIProfile"),
            workingDirectoryURL: URL(fileURLWithPath: "/fixture/WorkTurn.noindex/Work"),
            temporaryDirectoryURL: URL(fileURLWithPath: "/fixture/WorkTurn.noindex/Temp"),
            homeDirectoryURL: URL(fileURLWithPath: "/fixture"))
    }

    func service(_ store: SQLiteStore, runner: any ClaudeTextOnlyRunning, granted: Bool = true,
                 added: Bool = false) throws -> OfficialClaudeTextReplyService {
        OfficialClaudeTextReplyService(repository: store, teammates: store, conversations: store,
            messages: store, preparer: WorkTurnPreparer(target: try target()), runner: runner,
            appOwnerID: appOwner, webAccess: WorkTurnAccess(access: granted ? try access(added: added) : nil),
            approvals: store, activity: store)
    }
}

/// The sessions whose CLI files a turn removed.
private final class RemovedTranscripts: @unchecked Sendable {
    private let lock = NSLock()
    private var _ids: [UUID] = []
    var ids: [UUID] { lock.withLock { _ids } }
    func append(_ id: UUID) { lock.withLock { _ids.append(id) } }
}

/// The running apps on the user's Mac, as far as a turn's cleanup asks about them.
private final class FakeHiddenApps: HiddenAppQuitting, @unchecked Sendable {
    private let lock = NSLock()
    private var running: Set<String>
    private var _quitRequests: [String] = []
    init(running: Set<String>) { self.running = running }
    var quitRequests: [String] { lock.withLock { _quitRequests } }
    func isRunning(bundleIdentifier: String) -> Bool { lock.withLock { running.contains(bundleIdentifier) } }
    func quitIfHidden(bundleIdentifier: String) -> Bool {
        lock.withLock { _quitRequests.append(bundleIdentifier); return true }
    }
}
