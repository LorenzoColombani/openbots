import Foundation
import OpenBotsDomain
@testable import OpenBotsPersistence
import Testing
@testable import OpenBotsServices

@Suite("Durable chat service over a team conversation")
struct DurableTeammateChatTeamTests {
    struct Fixture {
        let directory: URL
        let receipt: ProtectionDecisionReceipt
        let date = Date(timeIntervalSince1970: 10)
        let ada = TeammateID(UUID()), mira = TeammateID(UUID()), zed = TeammateID(UUID())
        let adaChat = ConversationID(UUID()), miraChat = ConversationID(UUID()), zedChat = ConversationID(UUID())
        let teamID = TeamID(UUID()), teamChat = ConversationID(UUID())
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("durable-team-\(UUID()).noindex", isDirectory: true)
            receipt = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        func open() throws -> SQLiteStore {
            try SQLiteStore(configuration: SQLiteStoreConfiguration(
                fileURL: directory.appendingPathComponent("control.sqlite"), protection: .ordinarySQLite(decision: receipt)))
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
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
            let team = try Team(id: teamID, name: "QA Team", leadID: mira, memberIDs: [ada, mira], createdAt: date, updatedAt: date)
            try await store.provisionTeam(team,
                conversation: Conversation(id: teamChat, kind: .team(teamID: teamID), title: "QA Team", createdAt: date, updatedAt: date),
                selectConversation: true)
        }
        func service(_ store: SQLiteStore) -> DurableTeammateChatService {
            DurableTeammateChatService(teammateRepository: store, conversationRepository: store, messageRepository: store,
                                       provisioningRepository: store, selectionRepository: store)
        }
    }

    @Test("A saved team selection is not a direct chat, and does not break the direct-chat roster")
    func teamSelectionIsNotADirectChat() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let service = f.service(store)
        #expect(try await service.selectedDirectChat() == nil)
        #expect(try await service.activeDirectChats().count == 3)
    }

    @Test("Members save and page messages in the team conversation; a non-member is refused")
    func membersSaveAndPage() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let service = f.service(store)
        let first = try await service.saveMessageLocally(conversationID: f.teamChat, teammateID: f.mira,
            userMessageID: MessageID(UUID()), text: "Hello team", attachmentIDs: [])
        #expect(first.sequence == 1)
        let second = try await service.saveMessageLocally(conversationID: f.teamChat, teammateID: f.ada,
            userMessageID: MessageID(UUID()), text: "@Ada hello", attachmentIDs: [])
        #expect(second.sequence == 2)
        let page = try await service.loadMessages(conversationID: f.teamChat, beforeSequence: nil, limit: 10)
        #expect(page.messages.map(\.sequence) == [1, 2])
        await #expect(throws: DurableTeammateChatError.conversationIsNotActiveDirectChat(conversationID: f.teamChat, teammateID: f.zed)) {
            _ = try await service.saveMessageLocally(conversationID: f.teamChat, teammateID: f.zed,
                userMessageID: MessageID(UUID()), text: "I am not in this team", attachmentIDs: [])
        }
        #expect(try await service.loadMessages(conversationID: f.teamChat, beforeSequence: nil, limit: 10).messages.count == 2)
    }

    // An independent proof of the `loadMessages` change: messages are seeded
    // through the plain `MessageRepository.append` path, not through a save.
    @Test("loadMessages pages a team conversation once messages exist in it")
    func loadMessagesPagesATeamConversation() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let service = f.service(store)
        for sequence: Int64 in [1, 2] {
            let message = try Message(id: MessageID(UUID()), conversationID: f.teamChat, sequence: sequence,
                author: .user, deliveryState: .completed,
                parts: [try MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text("Message \(sequence)"))],
                createdAt: f.date, updatedAt: f.date)
            try await store.append(message, expectedPreviousSequence: sequence - 1)
        }
        let page = try await service.loadMessages(conversationID: f.teamChat, beforeSequence: nil, limit: 10)
        #expect(page.messages.map(\.sequence) == [1, 2])
    }

    // The transcript pages the conversation and hides every `workAudit` row
    // (briefs and reports live on the record). A page is a page of
    // what the transcript shows: a long run of hidden rows must never read as
    // an empty page, nor stop the paging before the real start.
    @Test("A run of work-audit rows longer than a page is skipped: every visible message is reached and hasMore stays truthful")
    func transcriptPagesSkipWorkAuditRuns() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let service = f.service(store)
        // 3 visible, then 12 hidden (more than the page of 5), then 4 visible.
        let classes: [OutputClass] = Array(repeating: .conversation, count: 3)
            + Array(repeating: .workAudit, count: 12)
            + Array(repeating: .conversation, count: 4)
        var visible: [Int64] = []
        for (offset, outputClass) in classes.enumerated() {
            let sequence = Int64(offset + 1)
            let message = try Message(id: MessageID(UUID()), conversationID: f.teamChat, sequence: sequence,
                author: outputClass == .workAudit ? .teammate(f.mira) : .user, outputClass: outputClass,
                deliveryState: .completed,
                parts: [try MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text("Message \(sequence)"))],
                createdAt: f.date, updatedAt: f.date)
            try await store.append(message, expectedPreviousSequence: sequence - 1)
            if outputClass != .workAudit { visible.append(sequence) }
        }
        #expect(visible == [1, 2, 3, 16, 17, 18, 19])

        // Page from the newest end the way the transcript does: the cursor is
        // the earliest row the previous page showed.
        var reached: [Int64] = []
        var cursor: Int64? = nil
        var pages = 0
        while true {
            let page = try await service.loadMessages(conversationID: f.teamChat, beforeSequence: cursor, limit: 5)
            pages += 1
            #expect(page.messages.allSatisfy { $0.outputClass != .workAudit }, "page \(pages) carried hidden rows")
            #expect(!page.messages.isEmpty, "page \(pages) read as empty although older visible rows exist")
            reached = page.messages.map(\.sequence) + reached
            guard page.hasMore, pages < 10 else { break }
            cursor = page.messages.first?.sequence
        }
        #expect(reached == visible)
        #expect(pages == 2)

        // hasMore is about visible rows: a cursor below which only hidden
        // rows remain reports the end, not a phantom earlier page.
        let end = try await service.loadMessages(conversationID: f.teamChat, beforeSequence: 4, limit: 5)
        #expect(end.messages.map(\.sequence) == [1, 2, 3])
        #expect(end.hasMore == false)
        #expect(end.nextBeforeSequence == nil)
        let onlyHidden = try await service.loadMessages(conversationID: f.teamChat, beforeSequence: 16, limit: 2)
        #expect(onlyHidden.messages.map(\.sequence) == [2, 3])
        #expect(onlyHidden.hasMore)
        #expect(onlyHidden.nextBeforeSequence == 2)
    }
}
