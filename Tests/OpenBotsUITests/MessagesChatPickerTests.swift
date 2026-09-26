import Foundation
import OpenBotsDomain
import OpenBotsServices
@testable import OpenBotsUI
import Testing

private let alice = "any;-;+33612345678"
private let family = "any;+;chat123456789012345678"
private let carrierInfo = "any;-;Carrier Info"

private actor FakeChatDirectory: MessagesChatDirectory {
    var list: [MessagesChatChoice]?
    var names: MessagesContactNames
    private(set) var asked = 0
    private(set) var reads = 0
    init(_ list: [MessagesChatChoice]?, names: MessagesContactNames = .refused) { self.list = list; self.names = names }
    func choices() async -> [MessagesChatChoice]? { reads += 1; return list }
    func contactNames() async -> MessagesContactNames { names }
    func askForContactNames() async {
        asked += 1
        names = .shown
        list = list?.map { $0.guid == alice
            ? MessagesChatChoice(guid: alice, title: "Alice Martin", detail: "+33612345678", lastMessageAt: nil,
                                 isChoosable: true)
            : $0 }
    }
}

private func choices() -> [MessagesChatChoice] {
    [MessagesChatChoice(guid: family, title: "Family", detail: "Group: Alice, +14155550100", lastMessageAt: nil,
                        isChoosable: true),
     MessagesChatChoice(guid: alice, title: "+33612345678", detail: nil, lastMessageAt: nil, isChoosable: true),
     MessagesChatChoice(guid: carrierInfo, title: "Carrier Info", detail: nil, lastMessageAt: nil, isChoosable: true)]
}

private actor MemoryRepository: ConnectorAccessRepository {
    var state = ConnectorAccessState()
    func loadConnectorAccess() async throws -> ConnectorAccessState { state }
    func saveConnectorAccess(_ next: ConnectorAccessState, expectedRevision: Int64) async throws {
        guard state.revision == expectedRevision else { throw ConnectorAccessError.staleRevision }
        state = next
    }
}

private struct MessagesAndMailCatalog: ConnectorCatalogReading {
    func loadConnectorCatalog() async throws -> ConnectorCatalogSnapshot {
        .init(connectors: [
            ConfiguredConnector(
                definition: .init(identity: try .init(id: AppOwnedConnectorCatalog.messagesConnectorID,
                                                      digest: String(repeating: "d", count: 64)),
                                  serverName: "apple-messages", pluginName: "apple-messages", transport: .stdio,
                                  title: "Messages (iMessage, RCS, SMS)", summary: "Sends and reads.",
                                  availability: .ready),
                launch: .init(serverKey: "", transport: .stdio, command: AppleMessagesConnectorPreparation.command)),
            ConfiguredConnector(
                definition: .init(identity: try .init(id: "openbots:apple-mail:apple-mail",
                                                      digest: String(repeating: "c", count: 64)),
                                  serverName: "apple-mail", pluginName: "apple-mail", transport: .stdio,
                                  title: "Apple Mail (read-only)", summary: "Reads mail.", availability: .ready),
                launch: .init(serverKey: "", transport: .stdio, command: "apple-mail-fast-mcp")),
        ])
    }
}

@MainActor
@Suite("Choosing the chats a bot may read in Messages")
struct MessagesChatPickerTests {
    private let messagesRow = "connector:\(AppOwnedConnectorCatalog.messagesConnectorID)"

    private func model(_ directory: FakeChatDirectory) async throws
        -> (BotAccessModel, ConnectorAccessStore, TeammateID) {
        let store = ConnectorAccessStore(repository: MemoryRepository(), catalog: MessagesAndMailCatalog())
        let bot = TeammateID(UUID())
        let model = BotAccessModel(teammateID: bot, botName: "Kite", switches: nil, connectors: store,
                                   messages: directory)
        await model.load()
        return (model, store, bot)
    }

    @Test("The Messages row says which chats the bot reads, by the names the user knows them by, and only it offers the choice")
    func theRowSaysWhichChats() async throws {
        let directory = FakeChatDirectory(choices())
        let (model, store, bot) = try await model(directory)
        defer { model.stopObserving() }
        #expect(model.row(messagesRow)?.notes.last == BotAccessCopy.messagesNoChats)
        #expect(model.offersChatChoice(rowID: messagesRow))
        #expect(!model.offersChatChoice(rowID: "connector:openbots:apple-mail:apple-mail"))
        #expect(model.row("connector:openbots:apple-mail:apple-mail")?.notes.contains(BotAccessCopy.messagesNoChats) == false)

        await model.setMessagesChats([alice, family])
        #expect(await store.messagesChats(teammateID: bot) == AppleMessagesChatScope(guids: [alice, family]))
        // In the order the picker lists them, newest first.
        #expect(model.row(messagesRow)?.notes.last == BotAccessCopy.messagesChats(["Family", "+33612345678"]))
        #expect(BotAccessCopy.messagesChats(["Family", "+33612345678"]) == "Reads only these chats: Family, +33612345678.")
        #expect(BotAccessCopy.messagesChats(["A", "B", "C", "D", "E"]) == "Reads only these chats: A, B, C and 2 more.")

        // A chat the user chose that Messages no longer keeps is still named, so
        // the user can take it out.
        await model.setMessagesChats([alice, "any;-;+19999999999"])
        #expect(model.row(messagesRow)?.notes.last
                == BotAccessCopy.messagesChats(["+33612345678", BotAccessCopy.chatGone]))
    }

    @Test("A history the app cannot read says so on the row, and offers no choice")
    func anUnreadableHistoryIsSaid() async throws {
        let (model, _, _) = try await model(FakeChatDirectory(nil))
        defer { model.stopObserving() }
        #expect(model.messagesHistoryIsUnreadable)
        #expect(model.row(messagesRow)?.notes.last == BotAccessCopy.messagesHistoryUnreadable)
        #expect(!model.offersChatChoice(rowID: messagesRow))
    }

    @Test("The picker ticks what the bot reads, finds a chat by what the user types, and stops at the limit")
    func thePickerTicksSearchesAndStops() async throws {
        let many = (0..<40).map { MessagesChatChoice(guid: "any;-;+336000000\($0)", title: "Person \($0)", detail: nil,
                                                      lastMessageAt: nil, isChoosable: true) }
        let long = MessagesChatChoice(guid: "any;-;long", title: "Too long", detail: nil, lastMessageAt: nil,
                                      isChoosable: false)
        let picker = MessagesChatPickerModel(botName: "Kite", choices: choices() + many + [long],
                                             chosen: AppleMessagesChatScope(guids: [alice, "any;-;+19999999999"]))
        // What the bot reads is on top: the chats the user chose, including one
        // Messages no longer keeps, then the rest newest first.
        #expect(Array(picker.visible.prefix(2).map(\.guid)) == [alice, "any;-;+19999999999"])
        #expect(picker.visible[1].title == BotAccessCopy.chatGone)
        #expect(picker.countLine == "2 of \(AppleMessagesChatScope.maximumChats) chosen")

        picker.search = "famil"
        #expect(picker.visible.map(\.guid) == [family])
        picker.search = "  CARRIER  "
        #expect(picker.visible.map(\.guid) == [carrierInfo])
        picker.search = ""

        #expect(!picker.canToggle(long.guid))
        picker.toggle(long.guid)
        #expect(!picker.isChosen(long.guid))

        for choice in many where picker.canToggle(choice.guid) { picker.toggle(choice.guid) }
        #expect(picker.selected.count == AppleMessagesChatScope.maximumChats)
        #expect(picker.limitReached)
        #expect(!picker.canToggle(family))
        #expect(picker.canToggle(alice), "a chosen chat can always be unticked")
        picker.toggle(alice)
        #expect(!picker.limitReached && picker.canToggle(family))
    }

    /// tccd's log on an installed build: without the Contacts entitlement
    /// the hardened-runtime app cannot raise the Contacts prompt, so a Mac that has
    /// never been asked may show no switch to turn on.
    @Test("With Contacts closed to the app, the picker says so and sends the user to no switch")
    func namesOffSendsTheUserNowhere() {
        #expect(!BotAccessCopy.contactNamesOff.contains("System Settings"))
        #expect(BotAccessCopy.contactNamesOff == "Names from Contacts are not shown: macOS does not let "
                + "OpenBots Next read Contacts. Each chat is listed by its number or address.")
    }

    @Test("Names from Contacts are asked for only when the user presses, and the list reads them at once")
    func namesAreAskedForOnlyOnTheUsersPress() async throws {
        let directory = FakeChatDirectory(choices(), names: .notAsked)
        let (model, _, _) = try await model(directory)
        defer { model.stopObserving() }
        #expect(model.contactNames == .notAsked)
        #expect(await directory.asked == 0)
        await model.askForContactNames()
        #expect(await directory.asked == 1)
        #expect(model.contactNames == .shown)
        #expect(model.messagesChoices?.first { $0.guid == alice }?.title == "Alice Martin")
    }
}

private struct MessagesAndContactsCatalog: ConnectorCatalogReading {
    var contacts: ConnectorAvailability = .ready
    func loadConnectorCatalog() async throws -> ConnectorCatalogSnapshot {
        .init(connectors: [
            ConfiguredConnector(
                definition: .init(identity: try .init(id: AppOwnedConnectorCatalog.messagesConnectorID,
                                                      digest: String(repeating: "d", count: 64)),
                                  serverName: "apple-messages", pluginName: "apple-messages", transport: .stdio,
                                  title: "Messages (iMessage, RCS, SMS)", summary: "Sends and reads.",
                                  availability: .ready),
                launch: .init(serverKey: "", transport: .stdio, command: AppleMessagesConnectorPreparation.command)),
            ConfiguredConnector(
                definition: .init(identity: try .init(id: AppOwnedConnectorCatalog.contactsConnectorID,
                                                      digest: String(repeating: "e", count: 64)),
                                  serverName: "apple-contacts", pluginName: "apple-contacts", transport: .stdio,
                                  title: "Contacts (read-only)", summary: "Looks people up.", availability: contacts),
                launch: .init(serverKey: "", transport: .stdio, command: AppleContactsConnectorPreparation.command)),
        ])
    }
}

/// The Messages read takes a number or an address, and a bot finds those through Contacts.
@MainActor
@Suite("The Messages row reminds the user that a bot finds people by name through Contacts")
struct MessagesNeedsContactsTests {
    @Test("Messages on and Contacts off: the row says so; Contacts on, or Messages off: it says nothing")
    func theReminderFollowsTheSwitches() async throws {
        let store = ConnectorAccessStore(repository: MemoryRepository(), catalog: MessagesAndContactsCatalog())
        let model = BotAccessModel(teammateID: TeammateID(UUID()), botName: "Kite", switches: nil, connectors: store,
                                   messages: FakeChatDirectory(choices()))
        await model.load()
        defer { model.stopObserving() }
        let messages = "connector:\(AppOwnedConnectorCatalog.messagesConnectorID)"
        let contacts = "connector:\(AppOwnedConnectorCatalog.contactsConnectorID)"
        #expect(model.row(messages)?.notes.contains(BotAccessCopy.messagesNeedsContacts) == false)
        await model.setOn(true, rowID: messages)
        #expect(model.row(messages)?.notes.contains(BotAccessCopy.messagesNeedsContacts) == true,
                "\(String(describing: model.row(messages)?.notes))")
        // Said before the chats line, which stays last where Choose Chats sits.
        #expect(model.row(messages)?.notes.last == BotAccessCopy.messagesNoChats)
        await model.setOn(true, rowID: contacts)
        #expect(model.row(messages)?.notes.contains(BotAccessCopy.messagesNeedsContacts) == false)
        #expect(BotAccessCopy.messagesNeedsContacts.contains("Contacts"))
    }

    @Test("Contacts that still needs setup is worth turning on, so the reminder shows; Contacts that cannot run is not")
    func theReminderFollowsWhetherContactsCanBeTurnedOn() async throws {
        let messages = "connector:\(AppOwnedConnectorCatalog.messagesConnectorID)"
        for (availability, shows) in [(ConnectorAvailability.needsSetup("Node is not found."), true),
                                      (.unavailable("Contacts is not installed on this Mac."), false)] {
            let store = ConnectorAccessStore(repository: MemoryRepository(),
                                             catalog: MessagesAndContactsCatalog(contacts: availability))
            let model = BotAccessModel(teammateID: TeammateID(UUID()), botName: "Kite", switches: nil,
                                       connectors: store, messages: FakeChatDirectory(choices()))
            await model.load()
            await model.setOn(true, rowID: messages)
            #expect(model.row(messages)?.notes.contains(BotAccessCopy.messagesNeedsContacts) == shows, "\(availability)")
            model.stopObserving()
        }
    }
}
