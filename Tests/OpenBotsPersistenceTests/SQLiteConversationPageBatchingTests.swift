import Foundation
import OpenBotsDomain
@testable import OpenBotsPersistence
import Testing

/// Opening a conversation reads one page of messages. What that page costs
/// is counted here in statements SQLite actually ran, not in what the source
/// looks like: a page used to cost one `message_parts` query per message and
/// its delivery notes one journal read per turn, a slow open felt in the app.
@Suite("A page of messages and its provenance cost a fixed number of statements")
struct SQLiteConversationPageBatchingTests {
    @Test("The statement trace records exactly what the connection ran, in order")
    func traceRecordsStatements() async throws {
        let f = try PageFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        await store.startStatementTrace()
        _ = try await store.query(sql: "SELECT id FROM conversations WHERE id=?;", bindings: [.text(f.conversationID.persistedValue)])
        _ = try await store.query(sql: "SELECT COUNT(*) AS n FROM messages;")
        let traced = await store.stopStatementTrace()
        #expect(traced == ["SELECT id FROM conversations WHERE id=?;", "SELECT COUNT(*) AS n FROM messages;"])
        // Off again: nothing after the stop is recorded.
        _ = try await store.query(sql: "SELECT 1 AS one;")
        #expect(await store.stopStatementTrace().isEmpty)
    }

    @Test("A page of 100 messages loads every part in one query")
    func pagePartsInOneQuery() async throws {
        let f = try PageFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let messages = try await f.appendMessages(store, count: 100)

        await store.startStatementTrace()
        let page = try await store.page(conversationID: f.conversationID, request: PageRequest(limit: 100))
        let full = await store.stopStatementTrace()
        // Content first: exactly what was appended, oldest first, every part
        // in ordinal order, and exactly what the one-message read decodes.
        #expect(page.elements == messages)
        #expect(!page.hasMore)
        // In the shapes the app writes: a user message is one text part; a
        // bot reply is its text and, after a failure, one diagnostic status.
        for message in page.elements {
            let contents = message.parts.map(\.content)
            if message.author == .user {
                #expect(contents == [.text("Message \(message.sequence)")], "user message \(message.sequence) has parts \(contents)")
            } else {
                #expect(contents == [.text("Message \(message.sequence)"), .status(PageFixture.replyStatus)],
                        "bot reply \(message.sequence) has parts \(contents)")
            }
        }
        var single: [Message] = []
        for message in messages { single.append(try #require(try await store.message(id: message.id))) }
        #expect(page.elements == single)

        // Cost: the page's rows, then every part of the page in one query.
        #expect(full.count == 2, "a page of 100 ran \(full.count) statements")
        await store.startStatementTrace()
        let short = try await store.page(conversationID: f.conversationID, request: PageRequest(limit: 10))
        let tenth = await store.stopStatementTrace()
        #expect(short.elements == Array(messages.suffix(10)) && short.hasMore)
        #expect(tenth.count == full.count, "a page of 10 ran \(tenth.count) statements, a page of 100 ran \(full.count)")
    }

    @Test("The provenance of a page of turns costs the same statements as the provenance of one")
    func provenanceReadsThePageAtOnce() async throws {
        let f = try PageFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let turns = try await f.runTurns(store, count: 25)
        let ids = try turns.flatMap { [$0.message.id, try #require($0.request.textTurnIdentity).replyMessageID] }

        await store.startStatementTrace()
        let records = try await store.textTurnProvenance(conversationID: f.conversationID, messageIDs: ids)
        let whole = await store.stopStatementTrace()

        // Content first: one record per turn naming its run, both its
        // messages, its bot, and how the turn went, exactly as the write
        // path reported it.
        #expect(records.count == turns.count)
        let byRun = Dictionary(uniqueKeysWithValues: records.map { ($0.runID, $0) })
        for turn in turns {
            let record = try #require(byRun[turn.request.runID])
            let identity = try #require(turn.request.textTurnIdentity)
            #expect(record.messageID == turn.message.id && record.replyMessageID == identity.replyMessageID)
            #expect(record.teammateID == f.teammateID && record.inputState == .acknowledged)
            #expect(record.state == turn.snapshot.run.state && record.outcome == turn.snapshot.outcome)
        }
        // And, in the repository's own order, what reading each turn on its
        // own returns: the batch changes the cost, never the answer.
        var single: [TextTurnMessageProvenance] = []
        for turn in turns {
            single += try await store.textTurnProvenance(conversationID: f.conversationID, messageIDs: [turn.message.id])
        }
        #expect(records == single.sorted { $0.runID.persistedValue < $1.runID.persistedValue })

        // Cost: the provenance of 25 turns runs exactly as many statements
        // as the provenance of one. It used to re-read each run's journal
        // record, input and reply, ten statements a turn.
        await store.startStatementTrace()
        _ = try await store.textTurnProvenance(conversationID: f.conversationID, messageIDs: Array(ids.prefix(2)))
        let one = await store.stopStatementTrace()
        #expect(whole.count == one.count, "25 turns ran \(whole.count) statements, one turn ran \(one.count)")
    }

    @Test("The fixture's bot reply is the shape the store writes for a failed turn")
    func fixtureReplyIsTheShapeTheStoreWrites() async throws {
        // One turn through the real writer, ended failed with a diagnostic.
        // finishTextTurn read that reply back through the store's own checks
        // before it returned, so the delivery state it carries, paired with
        // the status after its text, is a pairing the store accepts.
        let f = try PageFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let failed = try #require(try await f.runTurns(store, count: 3).first { $0.snapshot.outcome == .failed })
        let identity = try #require(failed.request.textTurnIdentity)
        let written = try #require(try await store.message(id: identity.replyMessageID))
        #expect(written.deliveryState == .failed && written.parts.count == 2)
        // The fixture's bot reply, appended into a store of its own, is that
        // shape, or the page tests pass on rows the app never writes.
        let g = try PageFixture()
        defer { g.remove() }
        let other = try g.open()
        try await g.seed(other)
        let appended = try #require(try await g.appendMessages(other, count: 2).last)
        #expect(appended.author == .teammate(g.teammateID) && appended.parts.count == 2)
        #expect(appended.deliveryState == written.deliveryState,
                "the fixture marks a reply with a status after its text \(appended.deliveryState), the store marks it \(written.deliveryState)")
        #expect(appended.parts.last?.content == written.parts.last?.content,
                "the fixture's status after the text is \(String(describing: appended.parts.last?.content)), the store writes \(String(describing: written.parts.last?.content))")
    }
}

/// One bot, one direct conversation, and the two ways a transcript fills:
/// plain appended messages, or text turns the journal knows about.
struct PageFixture: Sendable {
    let directory: URL
    let protection: ProtectionDecisionReceipt
    let date = Date(timeIntervalSince1970: 2_000)
    let teammateID = TeammateID(UUID())
    let conversationID = ConversationID(UUID())
    let appOwner = UUID(), owner = UUID(), token = UUID()

    init() throws {
        directory = URL(fileURLWithPath: "/private/tmp/OpenBotsNextPageBatching-\(UUID()).noindex", isDirectory: true)
        protection = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
    func at(_ offset: TimeInterval) -> Date { date.addingTimeInterval(offset) }
    func open() throws -> SQLiteStore {
        try SQLiteStore(configuration: SQLiteStoreConfiguration(fileURL: directory.appendingPathComponent("control.sqlite"),
            protection: .ordinarySQLite(decision: protection)))
    }

    func seed(_ store: SQLiteStore) async throws {
        let teammate = try Teammate(id: teammateID, profile: TeammateProfile(displayName: "Page Partner", role: "Research"),
            appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 6, silhouette: "round",
                paletteToken: "sky", eyeDialect: "bright", nonColorIdentityCue: "single crest", accessibleIdentityDescription: "Round creature with a crest"),
            createdAt: date, updatedAt: date)
        try await store.provisionDirectChat(teammate: teammate,
            conversation: Conversation(id: conversationID, kind: .direct(teammateID: teammateID), createdAt: date, updatedAt: date),
            fixtureGreeting: nil, selectConversation: false)
    }

    /// The one diagnostic a failed reply carries after its text, and the
    /// sentence the store saves it as. Only `finishTextTurn` writes a reply
    /// with a status after its text, and it marks that reply failed; the
    /// recovery path marks an interrupted reply outcomeUnknown and adds no
    /// status. A completed reply with a status after it is a shape the store
    /// refuses on read-back. `fixtureReplyIsTheShapeTheStoreWrites` holds
    /// the fixture to the writer.
    static let replyDiagnostic: TextTurnDiagnosticCode = .replayMessageMismatch
    static let replyStatus = "OpenBots diagnostic: \(replyDiagnostic.rawValue)"

    /// `count` messages, user and bot alternating, in the shapes the app
    /// writes: a user message is one text part, completed; a bot reply is
    /// its text and the one diagnostic status a failed reply carries after
    /// it, marked failed as the store marks it.
    func appendMessages(_ store: SQLiteStore, count: Int) async throws -> [Message] {
        var messages: [Message] = []
        for index in 1...count {
            let author: MessageAuthor = index.isMultiple(of: 2) ? .teammate(teammateID) : .user
            var parts = [try MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text("Message \(index)"))]
            if author != .user {
                parts.append(try MessagePart(id: MessagePartID(UUID()), ordinal: 1, content: .status(Self.replyStatus)))
            }
            let message = try Message(id: MessageID(UUID()), conversationID: conversationID, sequence: Int64(index),
                author: author, deliveryState: author == .user ? .completed : .failed, parts: parts,
                createdAt: at(TimeInterval(index)), updatedAt: at(TimeInterval(index)))
            try await store.append(message, expectedPreviousSequence: Int64(index - 1))
            messages.append(message)
        }
        return messages
    }

    struct Turn {
        let request: WorkRequest
        let message: Message
        let snapshot: TextTurnSnapshot
    }

    /// `count` text turns, each a user message and a bot reply. Every turn
    /// ends: all succeed but the last three, which fail with a diagnostic,
    /// are declined, and are left running with an acknowledged partial.
    func runTurns(_ store: SQLiteStore, count: Int) async throws -> [Turn] {
        var turns: [Turn] = []
        for index in 1...count {
            let text = "Question \(index)"
            let message = try Message(id: MessageID(UUID()), conversationID: conversationID, sequence: Int64(2 * index - 1),
                author: .user, deliveryState: .pending,
                parts: [MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text(text))],
                createdAt: date, updatedAt: date)
            let request = try WorkRequest(runID: RunID(UUID()), teammateID: teammateID, conversationID: conversationID,
                initiatingMessageID: message.id, profileRevision: 1,
                initialInput: WorkInput(messageID: message.id, sequence: 1, text: text), submittedAt: date,
                textTurnIdentity: TextTurnIdentity(appOwnerID: appOwner, replyMessageID: MessageID(UUID()), replyPartID: MessagePartID(UUID())))
            var current = try await store.beginTextTurn(request: request, userMessage: message,
                expectedPreviousSequence: message.sequence - 1, ownerID: owner, token: token, now: date, leaseDuration: 60)
            current = try await store.checkpointTextTurn(id: current.run.id, expectedRevision: current.run.revision,
                token: token, text: "", inputEvidence: .submitted, now: at(1))
            // A declined turn is one where the bot said nothing at all; any
            // partial text would read back as an ordinary failure.
            let partial = count - index == 1 ? "" : "Answer \(index)"
            current = try await store.checkpointTextTurn(id: current.run.id, expectedRevision: current.run.revision,
                token: token, text: partial, inputEvidence: .acknowledged, now: at(2))
            switch count - index {
            case 0:
                break
            case 1:
                current = try await store.finishTextTurn(id: current.run.id, expectedRevision: current.run.revision,
                    token: token, text: "", outcome: .declined, now: at(3))
            case 2:
                current = try await store.finishTextTurn(id: current.run.id, expectedRevision: current.run.revision,
                    token: token, text: "Answer \(index)", outcome: .failed, diagnosticCode: Self.replyDiagnostic, now: at(3))
            default:
                current = try await store.finishTextTurn(id: current.run.id, expectedRevision: current.run.revision,
                    token: token, text: "Answer \(index), done.", outcome: .succeeded, now: at(3))
            }
            turns.append(Turn(request: request, message: message, snapshot: current))
        }
        return turns
    }
}
