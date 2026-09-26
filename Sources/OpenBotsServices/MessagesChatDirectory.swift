import Contacts
import Foundation
import OpenBotsDomain
import OpenBotsPersistence

/// One conversation as the chat picker shows it: the words the user knows it by,
/// and the guid a bot's list names.
public struct MessagesChatChoice: Identifiable, Equatable, Sendable {
    public var id: String { guid }
    public let guid: String
    /// A contact's name, a group's name, or the address it is filed under.
    public let title: String
    /// The address under a contact's name, or who is in a group; nil when the
    /// title already says it all.
    public let detail: String?
    public let lastMessageAt: Date?
    /// False for the rare conversation whose guid is too long to name.
    public let isChoosable: Bool

    public init(guid: String, title: String, detail: String?, lastMessageAt: Date?, isChoosable: Bool) {
        self.guid = guid; self.title = title; self.detail = detail
        self.lastMessageAt = lastMessageAt; self.isChoosable = isChoosable
    }

    /// The most people a group's line names before it counts the rest.
    static let peopleNamed = 3

    /// How a conversation reads in the picker, with the names the user's Contacts give
    /// its addresses (keyed by `contactKey`). Names are display only: which
    /// chats a bot reads is decided by the guid alone.
    public static func make(_ conversation: MessagesConversation, names: [String: String]) -> MessagesChatChoice {
        func person(_ address: String) -> String { contactKey(address).flatMap { names[$0] } ?? address }
        let choosable = AppleMessagesChatScope.isChoosable(conversation.guid)
        if conversation.isGroup {
            let people = conversation.memberAddresses.map(person)
            var said = people.prefix(peopleNamed).joined(separator: ", ")
            if people.count > peopleNamed { said += " and \(people.count - peopleNamed) more" }
            let group = said.isEmpty ? "Group" : "Group: \(said)"
            if let name = conversation.displayName {
                return .init(guid: conversation.guid, title: name, detail: group,
                             lastMessageAt: conversation.lastMessageAt, isChoosable: choosable)
            }
            return .init(guid: conversation.guid, title: group, detail: nil,
                         lastMessageAt: conversation.lastMessageAt, isChoosable: choosable)
        }
        let address = conversation.identifier
        if let name = contactKey(address).flatMap({ names[$0] }) {
            return .init(guid: conversation.guid, title: name, detail: address,
                         lastMessageAt: conversation.lastMessageAt, isChoosable: choosable)
        }
        return .init(guid: conversation.guid, title: address.isEmpty ? conversation.guid : address, detail: nil,
                     lastMessageAt: conversation.lastMessageAt, isChoosable: choosable)
    }

    /// The key a Contacts name is filed under for an address: an email in
    /// lower case; a phone number by its last nine digits, the rule the server
    /// looks people up by (`matchClause` in apple-messages.js), so "06 12 34 56
    /// 78" in Contacts names "+33612345678" in Messages; a short number whole;
    /// and nothing for a sender like "Carrier Info", which no card would carry.
    public static func contactKey(_ address: String) -> String? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("@") { return trimmed.lowercased() }
        guard trimmed.allSatisfy({ $0.isNumber || " +().-".contains($0) }) else { return nil }
        let digits = trimmed.filter(\.isASCII).filter(\.isNumber)
        if digits.count >= 9 { return String(digits.suffix(9)) }
        return digits.count >= 3 ? digits : nil
    }
}

/// Whether the picker can show names from the user's Contacts.
public enum MessagesContactNames: Equatable, Sendable {
    case shown
    /// macOS has not asked the user yet; the picker offers to ask.
    case notAsked
    /// The user said no, or the Mac does not allow it.
    case refused
}

/// Where the picker's names come from.
public protocol MessagesContactNameSource: Sendable {
    func state() async -> MessagesContactNames
    /// Asks macOS, which asks the user once. Never called except by the user's press.
    func requestAccess() async
    /// Every name the user's Contacts give an address, keyed by `MessagesChatChoice.contactKey`;
    /// empty unless `state()` is `.shown`.
    func names() async -> [String: String]
}

/// The system's Contacts, read only when macOS already allows it: nothing here
/// raises a prompt except `requestAccess`, which only the user's press calls.
public struct SystemContactNameSource: MessagesContactNameSource {
    public init() {}

    public func state() async -> MessagesContactNames {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: .shown
        case .notDetermined: .notAsked
        default: .refused
        }
    }

    public func requestAccess() async {
        _ = try? await CNContactStore().requestAccess(for: .contacts)
    }

    public func names() async -> [String: String] {
        guard await state() == .shown else { return [:] }
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey,
                    CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
        var names: [String: String] = [:]
        try? CNContactStore().enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, _ in
            let person = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            let name = person.isEmpty ? contact.organizationName : person
            guard !name.isEmpty else { return }
            let addresses = contact.phoneNumbers.map(\.value.stringValue) + contact.emailAddresses.map { $0.value as String }
            for key in addresses.compactMap(MessagesChatChoice.contactKey) where names[key] == nil {
                names[key] = name
            }
        }
        return names
    }
}

/// The user's conversations for the picker, or why they cannot be listed.
public protocol MessagesChatDirectory: Sendable {
    /// Newest first; nil when the user's Messages history cannot be read here.
    func choices() async -> [MessagesChatChoice]?
    func contactNames() async -> MessagesContactNames
    func askForContactNames() async
}

/// The real directory: the user's own history, read by the app (which holds Full
/// Disk Access), and names from Contacts where macOS allows them.
public struct MessagesHistoryChatDirectory: MessagesChatDirectory {
    private let databaseURL: URL
    private let contacts: any MessagesContactNameSource

    public init(databaseURL: URL = AppOwnedConnectorCatalog.messagesDatabaseURL(
                    homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser),
                contacts: any MessagesContactNameSource = SystemContactNameSource()) {
        self.databaseURL = databaseURL; self.contacts = contacts
    }

    public func choices() async -> [MessagesChatChoice]? {
        guard let conversations = try? MessagesHistoryReader.conversations(databaseURL: databaseURL) else { return nil }
        let names = await contacts.names()
        return conversations.map { MessagesChatChoice.make($0, names: names) }
    }

    public func contactNames() async -> MessagesContactNames { await contacts.state() }
    public func askForContactNames() async { await contacts.requestAccess() }
}
