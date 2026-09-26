import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsServices

private actor FakeContactNames: MessagesContactNameSource {
    var current: MessagesContactNames
    let known: [String: String]
    private(set) var asked = 0
    init(_ state: MessagesContactNames, known: [String: String] = [:]) { current = state; self.known = known }
    func state() async -> MessagesContactNames { current }
    func requestAccess() async { asked += 1; current = .shown }
    func names() async -> [String: String] { current == .shown ? known : [:] }
}

@Suite("The chat picker's words for the user's conversations")
struct MessagesChatDirectoryTests {
    private func conversation(_ guid: String, _ identifier: String, name: String? = nil, group: Bool = false,
                              members: [String] = []) -> MessagesConversation {
        MessagesConversation(guid: guid, identifier: identifier, displayName: name, isGroup: group,
                             lastMessageAt: nil, memberAddresses: members)
    }

    @Test("A person reads as their Contacts name with the address beneath, and as the address without one")
    func aPersonReadsByName() {
        let names = ["612345678": "Alice Martin"]
        let alice = MessagesChatChoice.make(conversation("any;-;+33612345678", "+33612345678"), names: names)
        #expect(alice.title == "Alice Martin" && alice.detail == "+33612345678")
        let stranger = MessagesChatChoice.make(conversation("any;-;+14155550100", "+14155550100"), names: names)
        #expect(stranger.title == "+14155550100" && stranger.detail == nil)
        let sender = MessagesChatChoice.make(conversation("any;-;Carrier Info", "Carrier Info"), names: names)
        #expect(sender.title == "Carrier Info" && sender.isChoosable)
    }

    @Test("A group reads as its name with its people beneath, or as its people, counting past three")
    func aGroupReadsByItsPeople() {
        let names = ["612345678": "Alice", "550100123": "Bob"]
        let members = ["+14155550100", "+33612345678", "+15550100123", "+4915550001234", "+447700900123"]
        let named = MessagesChatChoice.make(conversation("any;+;chat1", "chat1", name: "Family", group: true,
                                                         members: members), names: names)
        #expect(named.title == "Family")
        #expect(named.detail == "Group: +14155550100, Alice, Bob and 2 more")
        let unnamed = MessagesChatChoice.make(conversation("any;+;chat2", "chat2", group: true,
                                                           members: Array(members.prefix(2))), names: names)
        #expect(unnamed.title == "Group: +14155550100, Alice" && unnamed.detail == nil)
    }

    @Test("A Contacts name is found by the server's own rule: an email in lower case, a number by its last nine digits")
    func theNameKeyIsTheServersRule() {
        #expect(MessagesChatChoice.contactKey("06 12 34 56 78") == "612345678")
        #expect(MessagesChatChoice.contactKey("+33 6 12 34 56 78") == "612345678")
        #expect(MessagesChatChoice.contactKey("+5215512345678") == MessagesChatChoice.contactKey("+525512345678"))
        #expect(MessagesChatChoice.contactKey("Alice@Example.COM") == "alice@example.com")
        #expect(MessagesChatChoice.contactKey("3600") == "3600")
        #expect(MessagesChatChoice.contactKey("12") == nil)
        #expect(MessagesChatChoice.contactKey("Carrier Info") == nil)
        #expect(MessagesChatChoice.contactKey("L'Atelier") == nil)
    }

    @Test("A conversation whose id is too long to name is listed and cannot be chosen")
    func aTooLongIdCannotBeChosen() {
        let long = "any;-;" + String(repeating: "9", count: AppleMessagesChatScope.maximumGUIDBytes)
        #expect(!MessagesChatChoice.make(conversation(long, "x"), names: [:]).isChoosable)
    }

    @Test("The directory lists the user's history with names only once macOS allows them, and asks only when told to")
    func theDirectoryAsksOnlyWhenTold() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("openbots-chat-directory-\(UUID().uuidString)", isDirectory: true)
        try FileManager().createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager().removeItem(at: root) }
        let database = root.appendingPathComponent("chat.db")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path, """
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE, id TEXT NOT NULL, service TEXT NOT NULL);
            CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE NOT NULL, style INTEGER,
                chat_identifier TEXT, display_name TEXT, last_read_message_timestamp INTEGER DEFAULT 0);
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER, message_date INTEGER DEFAULT 0,
                PRIMARY KEY (chat_id, message_id));
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER, UNIQUE(chat_id, handle_id));
            INSERT INTO chat(guid, style, chat_identifier) VALUES ('any;-;+33612345678', 45, '+33612345678');
            """]
        try process.run(); process.waitUntilExit()
        let contacts = FakeContactNames(.notAsked, known: ["612345678": "Alice Martin"])
        let directory = MessagesHistoryChatDirectory(databaseURL: database, contacts: contacts)
        #expect(await directory.choices()?.map(\.title) == ["+33612345678"])
        #expect(await directory.contactNames() == .notAsked)
        #expect(await contacts.asked == 0)
        await directory.askForContactNames()
        #expect(await contacts.asked == 1)
        #expect(await directory.choices()?.map(\.title) == ["Alice Martin"])
        let unreadable = MessagesHistoryChatDirectory(databaseURL: root.appendingPathComponent("absent.db"),
                                                      contacts: contacts)
        #expect(await unreadable.choices() == nil)
    }
}
