import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsPersistence

@Suite("Handoffs in SQLite")
struct SQLiteHandoffRepositoryTests {
    struct Fixture {
        let directory: URL
        let receipt: ProtectionDecisionReceipt
        let date = Date(timeIntervalSince1970: 10)
        let ada = TeammateID(UUID()), mira = TeammateID(UUID()), zed = TeammateID(UUID())
        let adaChat = ConversationID(UUID()), miraChat = ConversationID(UUID()), zedChat = ConversationID(UUID())
        let teamID = TeamID(UUID()), teamChat = ConversationID(UUID())
        let docsTeamID = TeamID(UUID()), docsChat = ConversationID(UUID())
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("handoffs-\(UUID()).noindex", isDirectory: true)
            receipt = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        func open() throws -> SQLiteStore {
            try SQLiteStore(configuration: SQLiteStoreConfiguration(
                fileURL: directory.appendingPathComponent("control.sqlite"), protection: .ordinarySQLite(decision: receipt)))
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
        /// Ada and Mira share both teams. Zed has a chat and no membership.
        func seed(_ store: SQLiteStore) async throws {
            for (id, chat, name) in [(ada, adaChat, "Ada"), (mira, miraChat, "Mira"), (zed, zedChat, "Zed")] {
                let bot = try Teammate(id: id, profile: TeammateProfile(displayName: name, role: "Research"),
                    appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 1, silhouette: "round",
                        paletteToken: "sky", eyeDialect: "bright", nonColorIdentityCue: "crest", accessibleIdentityDescription: "Round"),
                    createdAt: date, updatedAt: date)
                try await store.provisionDirectChat(teammate: bot,
                    conversation: Conversation(id: chat, kind: .direct(teammateID: id), createdAt: date, updatedAt: date),
                    fixtureGreeting: nil, selectConversation: false)
            }
            try await store.provisionTeam(Team(id: teamID, name: "QA Team", leadID: mira, memberIDs: [ada, mira], createdAt: date, updatedAt: date),
                conversation: Conversation(id: teamChat, kind: .team(teamID: teamID), title: "QA Team", createdAt: date, updatedAt: date),
                selectConversation: false)
            try await store.provisionTeam(Team(id: docsTeamID, name: "Docs Team", leadID: ada, memberIDs: [ada, mira], createdAt: date, updatedAt: date),
                conversation: Conversation(id: docsChat, kind: .team(teamID: docsTeamID), title: "Docs Team", createdAt: date, updatedAt: date),
                selectConversation: false)
        }
        func brief(_ goal: String = "Write a haiku about teamwork") throws -> HandoffBrief {
            try HandoffBrief(goal: goal, constraints: ["Three lines"], inputReferences: [],
                requestedOutput: "The haiku only", exclusions: [], stopOrApprovalBoundary: "Stop after one haiku")
        }
        /// A brief inside every domain grapheme cap whose JSON is far past the
        /// repository's byte cap: a grapheme is not a byte.
        func oversizedBrief() throws -> HandoffBrief {
            let wide = { (count: Int) in String(repeating: "\u{3042}", count: count) }
            return try HandoffBrief(goal: wide(2_000), constraints: Array(repeating: wide(1_000), count: 32),
                inputReferences: Array(repeating: wide(1_000), count: 64), requestedOutput: wide(2_000),
                exclusions: Array(repeating: wide(1_000), count: 32), stopOrApprovalBoundary: wide(2_000))
        }
        func record(sourceMessageID: MessageID? = nil, originConversationID: ConversationID? = nil,
                    receiverID: TeammateID? = nil, brief: HandoffBrief? = nil,
                    briefMessageID: MessageID? = nil, replyMessageID: MessageID? = nil,
                    runID: RunID? = nil) throws -> HandoffRecord {
            HandoffRecord(handoff: try Handoff(provenance: HandoffProvenance(handoffID: HandoffID(UUID()), legID: HandoffLegID(UUID()),
                originConversationID: originConversationID ?? teamChat, senderID: mira, receiverID: receiverID ?? ada, createdAt: date),
                brief: brief ?? self.brief()),
                sourceMessageID: sourceMessageID, briefMessageID: briefMessageID, replyMessageID: replyMessageID, runID: runID)
        }
        func message(author: MessageAuthor, sequence: Int64, text: String) throws -> Message {
            try Message(id: MessageID(UUID()), conversationID: teamChat, sequence: sequence, author: author, deliveryState: .completed,
                parts: [MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text(text))], createdAt: date, updatedAt: date)
        }
    }

    @Test("Sequential chain topology and hop budget survive reopening and reject forks or skipped hops")
    func durableChainBoundsAndTopology() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let root = try f.record()
        try await store.insert(root)
        func child(of parent: HandoffRecord, hop: Int? = nil, conversation: ConversationID? = nil) throws -> HandoffRecord {
            HandoffRecord(handoff: try Handoff(provenance: HandoffProvenance(handoffID: HandoffID(UUID()),
                legID: HandoffLegID(UUID()), originConversationID: conversation ?? f.teamChat,
                senderID: f.mira, receiverID: f.ada, createdAt: f.date), brief: f.brief()),
                sourceMessageID: nil, chainID: root.id, parentHandoffID: parent.id, hopCount: hop ?? parent.hopCount + 1)
        }
        var parent = root
        for hop in 1...HandoffRecord.maximumChainHops {
            try parent.apply(.accept(at: f.date))
            try await store.update(parent, expectedState: .staged)
            try parent.apply(.beginWork(at: f.date))
            try await store.update(parent, expectedState: .accepted)
            try parent.apply(.succeed(summary: "Result \(hop)", at: f.date))
            try await store.update(parent, expectedState: .working)
            if hop < HandoffRecord.maximumChainHops {
                let next = try child(of: parent)
                try await store.insert(next)
                await #expect(throws: (any Error).self) { try await store.insert(child(of: parent)) }
                await #expect(throws: (any Error).self) { try await store.insert(child(of: parent, hop: 1)) }
                await #expect(throws: (any Error).self) { try await store.insert(child(of: parent, conversation: f.docsChat)) }
                parent = next
            }
        }
        await #expect(throws: (any Error).self) { try await store.insert(child(of: parent)) }
        let reopened = try f.open()
        let saved = try await reopened.records(conversationID: f.teamChat)
        #expect(saved.count == HandoffRecord.maximumChainHops)
        #expect(Set(saved.map(\.chainID)) == [root.id])
        #expect(Set(saved.map(\.hopCount)) == Set(1...HandoffRecord.maximumChainHops))
    }

    @Test("A stopped chain cannot admit a new successor")
    func recoveryEndsChainAdmission() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        var root = try f.record()
        try await store.insert(root)
        try root.apply(.accept(at: f.date))
        try await store.update(root, expectedState: .staged)
        try root.apply(.beginWork(at: f.date))
        try await store.update(root, expectedState: .accepted)
        try root.apply(.succeed(summary: "Found a result", at: f.date))
        try await store.update(root, expectedState: .working)
        try root.apply(.requireRecovery(HandoffRecovery(code: "report-stopped", userMessage: "Stopped",
            isRecoverable: false, occurredAt: f.date)))
        try await store.update(root, expectedState: .succeeded)
        let successor = HandoffRecord(handoff: try Handoff(provenance: HandoffProvenance(handoffID: HandoffID(UUID()),
            legID: HandoffLegID(UUID()), originConversationID: f.teamChat, senderID: f.mira, receiverID: f.ada,
            createdAt: f.date), brief: f.brief()), sourceMessageID: nil, chainID: root.id, parentHandoffID: root.id, hopCount: 2)
        await #expect(throws: (any Error).self) { try await store.insert(successor) }
        #expect(try await store.records(conversationID: f.teamChat).count == 1)
    }

    @Test("A record round-trips through every state with compare-and-set updates")
    func roundTrip() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let source = try f.message(author: .teammate(f.mira), sequence: 1, text: "Here is the plan.")
        try await store.append(source, expectedPreviousSequence: 0)
        var record = try f.record(sourceMessageID: source.id)
        try await store.insert(record)
        #expect(try await store.records(conversationID: f.teamChat).map(\.id) == [record.id])
        #expect(try await store.record(id: record.id)?.state == .staged)
        try record.apply(.accept(at: f.date.addingTimeInterval(1)))
        try await store.update(record, expectedState: .staged)
        await #expect(throws: RepositoryError.optimisticLockFailed(entity: "handoff", id: record.id.persistedValue)) {
            try await store.update(record, expectedState: .staged)
        }
        try record.apply(.beginWork(at: f.date.addingTimeInterval(2)))
        record.runID = RunID(UUID())
        try await store.update(record, expectedState: .accepted)
        try record.apply(.succeed(summary: "Silent hands align", at: f.date.addingTimeInterval(3)))
        // `reply_message_id` references `messages(id)`, so the saved reply is a
        // real appended message rather than an unattached identifier.
        let reply = try f.message(author: .teammate(f.ada), sequence: 2, text: "Silent hands align.")
        try await store.append(reply, expectedPreviousSequence: 1)
        record.replyMessageID = reply.id
        try await store.update(record, expectedState: .working)
        let reopened = try f.open()
        let saved = try #require(try await reopened.record(id: record.id))
        #expect(saved.state == .succeeded && saved.handoff.resultSummary == "Silent hands align" && saved.runID == record.runID)
        #expect(saved.sourceMessageID == source.id && saved.replyMessageID == record.replyMessageID)
        try record.apply(.returnToOrigin(at: f.date.addingTimeInterval(4)))
        try await reopened.update(record, expectedState: .succeeded)
        #expect(try await reopened.record(id: record.id)?.handoff.returnedAt == f.date.addingTimeInterval(4))
        var declined = try f.record()
        try await reopened.insert(declined)
        try declined.apply(.requireRecovery(HandoffRecovery(code: "declined", userMessage: "Not sent.", isRecoverable: false, occurredAt: f.date.addingTimeInterval(5))))
        try await reopened.update(declined, expectedState: .staged)
        #expect(try await reopened.record(id: declined.id)?.handoff.recovery?.code == "declined")
        #expect(try await reopened.records(conversationID: f.teamChat).map(\.id) == [declined.id, record.id])
    }

    @Test("An origin must be a team conversation both parties still belong to")
    func originMustBeASharedTeam() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        // A direct conversation is never a handoff origin.
        let direct = await #expect(throws: (any Error).self) {
            try await store.insert(f.record(originConversationID: f.adaChat))
        }
        // Zed has a chat but no membership in the origin's team.
        let outsider = await #expect(throws: (any Error).self) {
            try await store.insert(f.record(receiverID: f.zed))
        }
        // The schema trigger refused both, not some unrelated failure.
        for refusal in [direct, outsider] {
            #expect(String(describing: try #require(refusal)).contains("team conversation both parties belong to"))
        }
        #expect(try await store.records(conversationID: f.teamChat).isEmpty)
        #expect(try await store.records(conversationID: f.adaChat).isEmpty)
    }

    @Test("Insertion refuses an oversized brief and a record that already claims its messages or run")
    func insertionValidatesBeforeWriting() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        await #expect(throws: DomainValidationError.invalid(field: "handoff brief", reason: "encodes to more than 262144 bytes")) {
            try await store.insert(f.record(brief: f.oversizedBrief()))
        }
        for claimed in [try f.record(briefMessageID: MessageID(UUID())),
                        try f.record(replyMessageID: MessageID(UUID())),
                        try f.record(runID: RunID(UUID()))] {
            await #expect(throws: DomainValidationError.invalid(field: "handoff insertion",
                reason: "a new handoff has no brief message, reply or run")) {
                try await store.insert(claimed)
            }
        }
        #expect(try await store.records(conversationID: f.teamChat).isEmpty)
    }

    @Test("A text turn takes a sender-authored input only for an accepted leg whose parties match")
    func legInputIsVerified() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        var record = try f.record()
        try await store.insert(record)
        let now = f.date.addingTimeInterval(10)
        let appOwner = UUID(), ownerID = UUID(), token = UUID()
        let briefText = "Handoff from Mira: write a haiku about teamwork."
        func request(receiver: TeammateID, message: Message, leg: HandoffLegID?) async throws -> WorkRequest {
            let bot = try #require(try await store.teammate(id: receiver))
            return try WorkRequest(runID: RunID(UUID()), teammateID: receiver, conversationID: f.teamChat, initiatingMessageID: message.id,
                selectedProjectID: nil, profileRevision: bot.profile.revision,
                initialInput: WorkInput(messageID: message.id, sequence: 1, text: briefText),
                submittedAt: now, textTurnIdentity: TextTurnIdentity(appOwnerID: appOwner, replyMessageID: MessageID(UUID()),
                    replyPartID: MessagePartID(UUID()), handoffLegID: leg), readContextReceipt: nil)
        }
        // A brief is the work channel, so a leg's input is work-audit.
        func input(author: MessageAuthor, outputClass: OutputClass = .workAudit) throws -> Message {
            try Message(id: MessageID(UUID()), conversationID: f.teamChat, sequence: 1, author: author, outputClass: outputClass,
                deliveryState: .pending,
                parts: [MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text(briefText))], createdAt: now, updatedAt: now)
        }
        // Staged (not yet accepted): refused.
        let early = try input(author: .teammate(f.mira))
        await #expect(throws: TextTurnRepositoryError.invalidRequest) {
            _ = try await store.beginTextTurn(request: request(receiver: f.ada, message: early, leg: record.legID), userMessage: early,
                expectedPreviousSequence: 0, ownerID: ownerID, token: token, now: now, leaseDuration: 60)
        }
        try record.apply(.accept(at: now))
        try await store.update(record, expectedState: .staged)
        // Wrong author (a user message) for a leg: refused.
        let userAuthored = try input(author: .user)
        await #expect(throws: TextTurnRepositoryError.invalidRequest) {
            _ = try await store.beginTextTurn(request: request(receiver: f.ada, message: userAuthored, leg: record.legID), userMessage: userAuthored,
                expectedPreviousSequence: 0, ownerID: ownerID, token: token, now: now, leaseDuration: 60)
        }
        // Wrong receiver: refused.
        let forMira = try input(author: .teammate(f.mira))
        await #expect(throws: TextTurnRepositoryError.invalidRequest) {
            _ = try await store.beginTextTurn(request: request(receiver: f.mira, message: forMira, leg: record.legID), userMessage: forMira,
                expectedPreviousSequence: 0, ownerID: ownerID, token: token, now: now, leaseDuration: 60)
        }
        // A brief saved as a transcript message: refused, it belongs to the record.
        let transcriptClassed = try input(author: .teammate(f.mira), outputClass: .conversation)
        await #expect(throws: TextTurnRepositoryError.invalidRequest) {
            _ = try await store.beginTextTurn(request: request(receiver: f.ada, message: transcriptClassed, leg: record.legID), userMessage: transcriptClassed,
                expectedPreviousSequence: 0, ownerID: ownerID, token: token, now: now, leaseDuration: 60)
        }
        // A teammate-authored input without a leg id: refused (direct-chat rule unchanged).
        let noLeg = try input(author: .teammate(f.mira))
        await #expect(throws: TextTurnRepositoryError.invalidRequest) {
            _ = try await store.beginTextTurn(request: request(receiver: f.ada, message: noLeg, leg: nil), userMessage: noLeg,
                expectedPreviousSequence: 0, ownerID: ownerID, token: token, now: now, leaseDuration: 60)
        }
        // An accepted leg whose origin is a different team conversation: refused.
        var elsewhere = try f.record(originConversationID: f.docsChat)
        try await store.insert(elsewhere)
        try elsewhere.apply(.accept(at: now))
        try await store.update(elsewhere, expectedState: .staged)
        let otherOrigin = try input(author: .teammate(f.mira))
        await #expect(throws: TextTurnRepositoryError.invalidRequest) {
            _ = try await store.beginTextTurn(request: request(receiver: f.ada, message: otherOrigin, leg: elsewhere.legID), userMessage: otherOrigin,
                expectedPreviousSequence: 0, ownerID: ownerID, token: token, now: now, leaseDuration: 60)
        }
        #expect(try await store.page(conversationID: f.teamChat, request: PageRequest(limit: 5)).elements.isEmpty)
        // The real leg: accepted.
        let good = try input(author: .teammate(f.mira))
        let snapshot = try await store.beginTextTurn(request: request(receiver: f.ada, message: good, leg: record.legID), userMessage: good,
            expectedPreviousSequence: 0, ownerID: ownerID, token: token, now: now, leaseDuration: 60)
        #expect(snapshot.run.request.teammateID == f.ada)
        let page = try await store.page(conversationID: f.teamChat, request: PageRequest(limit: 5)).elements
        #expect(page.map(\.author) == [.teammate(f.mira), .teammate(f.ada)])
        // The member's reply to a brief is the work channel too.
        #expect(page.map(\.outputClass) == [.workAudit, .workAudit])
        // The receiver starts work. Rehydrating a committed turn must not depend
        // on the leg still being `accepted`, so recovery and checkpoints survive.
        try record.apply(.beginWork(at: now))
        try await store.update(record, expectedState: .accepted)
        #expect(try await store.pendingTextTurns(appOwnerID: appOwner, limit: 5).map(\.run.id) == [snapshot.run.id])
        let checkpointed = try await store.checkpointTextTurn(id: snapshot.run.id, expectedRevision: snapshot.run.revision,
            token: token, text: "Silent hands", inputEvidence: .submitted, now: now.addingTimeInterval(1))
        #expect(checkpointed.replyText == "Silent hands")
    }
}
